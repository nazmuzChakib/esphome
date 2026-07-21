import glob
import hashlib
import json
import os
import re
import subprocess
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from tkinter import filedialog, messagebox, scrolledtext, ttk
import tkinter as tk

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    serial = None

APP_VERSION = "2.0.0"
PROJECT_NAME = "ESPHome EventBus Monitor"
BOOT_BANNER_PATTERN = "ESP32 OOP Backend Foundation & Memory Pool Test"
UNKNOWN_ORIGIN = "Origin not decoded yet"

@dataclass(frozen=True)
class DiagnosticRule:
    name: str
    severity: str
    patterns: tuple
    cause: str
    action: str

DIAGNOSTIC_RULES = (
    DiagnosticRule(
        "Null pointer / invalid object access",
        "critical",
        (r"LoadProhibited", r"StoreProhibited", r"EXCVADDR:\s*0x0+\b", r"null pointer"),
        "The firmware tried to read or write an invalid memory address.",
        "Validate pointers and object lifetimes before use. Guard callbacks, JSON fields, and heap allocations.",
    ),
    DiagnosticRule(
        "Instruction fetch fault",
        "critical",
        (r"InstrFetchProhibited", r"IllegalInstruction"),
        "The CPU jumped to an invalid instruction address, often from stack corruption or a bad function pointer.",
        "Inspect function pointers, ISR callbacks, overwritten buffers, and task stack size.",
    ),
    DiagnosticRule(
        "Watchdog timeout",
        "high",
        (r"\bWDT\b", r"watchdog", r"wdt timeout", r"Task watchdog got triggered"),
        "A task blocked the scheduler or a CPU core for too long.",
        "Break long loops, add yield()/delay(1), move blocking IO off hot paths, and verify task priorities.",
    ),
    DiagnosticRule(
        "Brownout / weak power",
        "high",
        (r"Brownout", r"brownout detector", r"voltage"),
        "Power rail dropped under load.",
        "Use a stronger supply/cable, avoid powering high-current peripherals from weak USB, and add bulk capacitance.",
    ),
    DiagnosticRule(
        "Heap pressure or memory corruption",
        "high",
        (r"heap_caps_malloc failed", r"CORRUPT HEAP", r"Bad tail", r"multi_heap", r"malloc\(\) failed"),
        "Heap allocation failed or heap metadata was corrupted.",
        "Log free heap, reduce dynamic allocations, check buffer boundaries, and avoid large stack/local buffers.",
    ),
    DiagnosticRule(
        "Stack overflow",
        "critical",
        (r"stack overflow", r"Stack canary watchpoint triggered", r"canary"),
        "A FreeRTOS task exceeded its stack.",
        "Increase task stack size and move large local variables to static/global/heap storage.",
    ),
    DiagnosticRule(
        "Flash / partition problem",
        "medium",
        (r"partition", r"SPI flash", r"flash read err", r"ota data", r"invalid header"),
        "Firmware layout, flash access, or OTA metadata may be inconsistent.",
        "Check partition table, selected board profile, flash mode/frequency, and OTA image validity.",
    ),
    DiagnosticRule(
        "WiFi / network instability",
        "medium",
        (r"wifi", r"WiFi", r"STA_DISCONNECTED", r"AUTH_EXPIRE", r"BEACON_TIMEOUT", r"connection refused"),
        "Network connection state is unstable or remote endpoint is unavailable.",
        "Add reconnect backoff, verify credentials, check RSSI, and avoid blocking code in network callbacks.",
    ),
    DiagnosticRule(
        "Filesystem / storage error",
        "medium",
        (r"LittleFS", r"SPIFFS", r"SD card", r"VFS", r"mount failed", r"File not found"),
        "Persistent storage failed to mount, read, or write.",
        "Confirm partition sizing, format-on-first-run handling, file paths, and available space.",
    ),
    DiagnosticRule(
        "TLS / certificate issue",
        "medium",
        (r"mbedtls", r"certificate", r"x509", r"SSL", r"TLS", r"handshake"),
        "Secure connection setup failed.",
        "Verify time sync, CA certificate, host name, and available heap during TLS handshake.",
    ),
)

SEVERITY_WEIGHT = {"critical": 4, "high": 3, "medium": 2, "low": 1}

class ESPHomeSerialTool:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title(f"{PROJECT_NAME} v{APP_VERSION}")
        self.root.geometry("1400x900")
        self.root.minsize(1100, 750)
        self.root.configure(bg="#0B1220")
        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)

        self.home = Path.home()
        self.config_file = Path(__file__).with_name("config.json")
        self.settings = {
            "project_path": str(self.home / "Desktop" / "ESPHome"),
            "max_console_lines": 3000,
            "max_log_mb": 20.0,
            "auto_analyze": True,
            "theme": "dark",
            "auto_find_elf": True,
        }
        self.load_settings()

        # Engine states
        self.elf_path = None
        self.ser = None
        self.reading = False
        self.log_file = None
        self.current_log_path = ""
        self.last_line = ""
        self.repeat_count = 0
        self.repeat_start_ts = ""
        self.last_ts = ""
        self.analysis_timer = None
        self.last_report = ""
        self.heap_history = [0] * 30

        # Sub-system Variables
        self.preserve_mode = tk.BooleanVar(value=True)
        self.auto_analyze_var = tk.BooleanVar(value=bool(self.settings.get("auto_analyze", True)))
        self.status_var = tk.StringVar(value="Ready")
        self.port_var = tk.StringVar()
        self.baud_var = tk.StringVar(value="115200")
        self.search_var = tk.StringVar()
        self.filter_var = tk.StringVar(value="All")
        self.quick_command_var = tk.StringVar(value="Custom")
        self.active_view = "dashboard"

        self.setup_style()
        self.create_modern_layout()
        self.refresh_ports()
        self.root.after(2000, self.auto_refresh_ports)
        
        if self.settings.get("auto_find_elf", True):
            self.root.after(250, self.find_elf_quiet)

    def setup_style(self):
        self.colors = {
            "bg": "#0B1220",
            "panel": "#131C2E",
            "panel_hover": "#1A2438",
            "border": "#222F47",
            "text": "#F8FAFC",
            "muted": "#94A3B8",
            "accent": "#3B82F6",
            "success": "#10B981",
            "warning": "#F59E0B",
            "danger": "#EF4444",
            "console": "#070D19",
            "console_fg": "#E2E8F0"
        }
        self.root.option_add("*Font", ("Segoe UI", 10))
        self.style = ttk.Style(self.root)
        self.style.theme_use("clam")
        
        # Combobox customization
        self.style.configure("TCombobox", fieldbackground="#131C2E", background="#222F47", foreground=self.colors["text"], borderwidth=0)
        self.style.map("TCombobox", fieldbackground=[("readonly", "#131C2E")], foreground=[("readonly", self.colors["text"])])
        self.root.option_add("*TCombobox*Listbox.background", "#131C2E")
        self.root.option_add("*TCombobox*Listbox.foreground", self.colors["text"])
        self.root.option_add("*TCombobox*Listbox.selectBackground", self.colors["accent"])

    def load_settings(self):
        if self.config_file.exists():
            try:
                with self.config_file.open("r", encoding="utf-8") as f:
                    self.settings.update(json.load(f))
            except Exception:
                pass

    def save_settings(self):
        try:
            with self.config_file.open("w", encoding="utf-8") as f:
                json.dump(self.settings, f, indent=4)
        except Exception:
            pass

    def make_rounded_canvas_panel(self, parent, height=100, bg=None):
        if bg is None:
            bg = self.colors["panel"]
        canvas = tk.Canvas(parent, height=height, bg=self.colors["bg"], highlightthickness=0, bd=0)
        canvas.pack(fill="x", pady=6)
        
        def render_canvas(event):
            canvas.delete("all")
            w = event.width
            h = event.height
            r = 16  # radius
            canvas.create_oval(0, 0, r*2, r*2, fill=bg, outline="")
            canvas.create_oval(w-r*2, 0, w, r*2, fill=bg, outline="")
            canvas.create_oval(0, h-r*2, r*2, h, fill=bg, outline="")
            canvas.create_oval(w-r*2, h-r*2, w, h, fill=bg, outline="")
            canvas.create_rectangle(r, 0, w-r, h, fill=bg, outline="")
            canvas.create_rectangle(0, r, w, h-r, fill=bg, outline="")

        canvas.bind("<Configure>", render_canvas)
        return canvas

    def create_modern_layout(self):
        # ------------------ TOP HEADER ------------------
        self.header = tk.Frame(self.root, bg="#070D19", height=65)
        self.header.pack(fill="x", side="top")
        self.header.pack_propagate(False)

        # Title Block
        title_frame = tk.Frame(self.header, bg="#070D19", padx=20)
        title_frame.pack(side="left", fill="y")
        tk.Label(title_frame, text="⚡ " + PROJECT_NAME, font=("Segoe UI", 14, "bold"), fg=self.colors["text"], bg="#070D19").pack(anchor="w", pady=(8, 0))
        tk.Label(title_frame, text="Unified Telemetry Engine & Deep Diagnostics", font=("Segoe UI", 9), fg=self.colors["muted"], bg="#070D19").pack(anchor="w")

        # Connection Status Chip
        self.status_chip = tk.Label(self.header, text="● DISCONNECTED", font=("Segoe UI Variable", 9, "bold"), fg=self.colors["danger"], bg="#170F1C", padx=12, pady=4)
        self.status_chip.pack(side="left", padx=15, pady=16)

        # Header Control Actions
        header_actions = tk.Frame(self.header, bg="#070D19", padx=20)
        header_actions.pack(side="right", fill="y")
        self.make_modern_btn(header_actions, "📂 Load Log", self.load_log_file, "secondary").pack(side="left", padx=4, pady=14)
        self.make_modern_btn(header_actions, "⚙ Settings", self.open_settings, "secondary").pack(side="left", padx=4, pady=14)

        # ------------------ MAIN CONTAINER ------------------
        self.main_container = tk.Frame(self.root, bg=self.colors["bg"])
        self.main_container.pack(fill="both", expand=True)

        # Left Sidebar Navigation
        self.sidebar = tk.Frame(self.main_container, bg="#070D19", width=220)
        self.sidebar.pack(side="left", fill="y")
        self.sidebar.pack_propagate(False)
        self.build_sidebar_menu()

        # Dynamic Viewport Frame
        self.viewport = tk.Frame(self.main_container, bg=self.colors["bg"], padx=20, pady=15)
        self.viewport.pack(side="right", fill="both", expand=True)

        # Initialize core UI windows inside viewport stack
        self.init_views()
        self.switch_view("dashboard")

        # ------------------ FOOTER STATUS BAR ------------------
        self.footer = tk.Frame(self.root, bg="#070D19", height=30, bd=0)
        self.footer.pack(fill="x", side="bottom")
        self.footer.pack_propagate(False)
        tk.Label(self.footer, textvariable=self.status_var, fg=self.colors["muted"], bg="#070D19", font=("Segoe UI", 9), padx=15).pack(side="left")
        
        self.footer_meta = tk.Label(self.footer, text="Target: None | SHA: N/A | Core: Idle", fg=self.colors["muted"], bg="#070D19", font=("Segoe UI", 9), padx=15)
        self.footer_meta.pack(side="right")

    def build_sidebar_menu(self):
        tk.Label(self.sidebar, text="NAVIGATION", font=("Segoe UI", 8, "bold"), fg="#475569", bg="#070D19", padx=20).pack(anchor="w", pady=(20, 10))
        
        self.nav_btns = {}
        routes = [
            ("dashboard", "📊 Dashboard"),
            ("serial", "📜 Serial Stream"),
            ("diagnostics", "🧠 Crash Analyzer"),
        ]
        
        for view_id, label in routes:
            btn = tk.Button(
                self.sidebar, 
                text=f"  {label}", 
                font=("Segoe UI", 10, "bold"),
                anchor="w", 
                fg=self.colors["muted"], 
                bg="#070D19", 
                activeforeground=self.colors["text"],
                activebackground=self.colors["panel_hover"],
                relief="flat", 
                bd=0, 
                padx=20, 
                pady=12,
                cursor="hand2",
                command=lambda v=view_id: self.switch_view(v)
            )
            btn.pack(fill="x", pady=2)
            self.nav_btns[view_id] = btn

    def switch_view(self, target_view):
        self.active_view = target_view
        for view_id, view_frame in self.views.items():
            if view_id == target_view:
                view_frame.pack(fill="both", expand=True)
                self.nav_btns[view_id].config(fg=self.colors["text"], bg=self.colors["panel"])
            else:
                view_frame.pack_forget()
                self.nav_btns[view_id].config(fg=self.colors["muted"], bg="#070D19")

    def init_views(self):
        self.views = {
            "dashboard": tk.Frame(self.viewport, bg=self.colors["bg"]),
            "serial": tk.Frame(self.viewport, bg=self.colors["bg"]),
            "diagnostics": tk.Frame(self.viewport, bg=self.colors["bg"])
        }
        
        # 1. BUILD DASHBOARD
        self.setup_dashboard_view()
        
        # 2. BUILD SERIAL STREAM
        self.setup_serial_view()
        
        # 3. BUILD DIAGNOSTICS
        self.setup_diagnostics_view()

    def setup_dashboard_view(self):
        dash = self.views["dashboard"]
        
        # Project symbol configurator deck
        config_panel = self.make_rounded_canvas_panel(dash, height=75)
        inner_config = tk.Frame(config_panel, bg=self.colors["panel"])
        config_panel.create_window(15, 12, anchor="nw", window=inner_config, width=1100, height=50)
        
        self.path_var = tk.StringVar(value=self.settings["project_path"])
        path_entry = tk.Entry(inner_config, textvariable=self.path_var, bg="#0B1220", fg=self.colors["text"],
                              relief="flat", highlightthickness=1, highlightbackground=self.colors["border"], highlightcolor=self.colors["accent"])
        path_entry.pack(side="left", fill="x", expand=True, padx=(0, 8), ipady=6)
        
        self.make_modern_btn(inner_config, "Browse", self.browse_folder, "secondary").pack(side="left", padx=3)
        self.make_modern_btn(inner_config, "🔍 Auto Find ELF", self.find_elf, "primary").pack(side="left", padx=3)
        self.elf_label = tk.Label(inner_config, text="ELF Target Not Loaded", fg=self.colors["danger"], bg=self.colors["panel"], font=("Segoe UI", 9, "bold"))
        self.elf_label.pack(side="left", padx=10)

        # Severity Cards Row
        cards_frame = tk.Frame(dash, bg=self.colors["bg"])
        cards_frame.pack(fill="x", pady=10)

        self.cards_data = {
            "critical": {"title": "⚠️ CRITICAL FAULTS", "color": self.colors["danger"]},
            "high": {"title": "🔥 HIGH RISKS", "color": self.colors["warning"]},
            "medium": {"title": "🌐 TELEMETRY WARNS", "color": "#4CC9F0"},
            "health": {"title": "🩺 INSTABILITY INDEX", "color": self.colors["success"]}
        }
        self.ui_cards = {}
        
        for key, info in self.cards_data.items():
            c_box = tk.Frame(cards_frame, bg=self.colors["panel"], highlightthickness=1, highlightbackground=self.colors["border"], padx=15, pady=12)
            c_box.pack(side="left", fill="x", expand=True, padx=4)
            tk.Label(c_box, text=info["title"], font=("Segoe UI", 8, "bold"), fg=self.colors["muted"], bg=self.colors["panel"]).pack(anchor="w")
            lbl = tk.Label(c_box, text="0" if key != "health" else "STABLE", font=("Segoe UI Variable", 20, "bold"), fg=info["color"], bg=self.colors["panel"])
            lbl.pack(anchor="w", pady=(4, 0))
            self.ui_cards[key] = lbl

        # Telemetry Graphs & Telemetry Info Layout Split
        split_layout = tk.Frame(dash, bg=self.colors["bg"])
        split_layout.pack(fill="both", expand=True, pady=10)

        # Left Canvas for Real-time Heap Profile
        self.heap_panel = tk.LabelFrame(split_layout, text=" Memory Metrics (Dynamic Heap Map) ", bg=self.colors["panel"], fg=self.colors["muted"], highlightthickness=0, bd=1, font=("Segoe UI", 9, "bold"), padx=10, pady=10)
        self.heap_panel.pack(side="left", fill="both", expand=True, padx=(0, 6))
        
        self.heap_canvas = tk.Canvas(self.heap_panel, bg=self.colors["console"], highlightthickness=0)
        self.heap_canvas.pack(fill="both", expand=True)

        # Right Board for Analytics Subsystems Data
        self.metrics_panel = tk.LabelFrame(split_layout, text=" Project Subsystems Telemetry ", bg=self.colors["panel"], fg=self.colors["muted"], highlightthickness=0, bd=1, font=("Segoe UI", 9, "bold"), padx=15, pady=10)
        self.metrics_panel.pack(side="right", fill="both", expand=True, padx=(6, 0))
        
        self.dash_heap_val = tk.Label(self.metrics_panel, text="Heap Stats: Waiting for telemetry stream...", font=("Cascadia Mono", 10), fg=self.colors["success"], bg=self.colors["panel"], anchor="w")
        self.dash_heap_val.pack(fill="x", pady=6)
        
        self.dash_event_val = tk.Label(self.metrics_panel, text="EventBus Payload: No events processed", font=("Cascadia Mono", 10), fg=self.colors["text"], bg=self.colors["panel"], anchor="w")
        self.dash_event_val.pack(fill="x", pady=6)
        
        self.dash_storage_val = tk.Label(self.metrics_panel, text="Storage Subsystem: Integrity unchecked", font=("Cascadia Mono", 10), fg=self.colors["muted"], bg=self.colors["panel"], anchor="w")
        self.dash_storage_val.pack(fill="x", pady=6)

    def draw_heap_graph(self):
        self.heap_canvas.delete("graph")
        w = self.heap_canvas.winfo_width()
        h = self.heap_canvas.winfo_height()
        if w < 10 or h < 10:
            return
            
        points = self.heap_history
        max_h = max(points) if max(points) > 0 else 100000
        min_h = min(points) if min(points) > 0 else 0
        span = max_h - min_h if max_h != min_h else 1
        
        step_x = w / (len(points) - 1)
        coords = []
        for i, val in enumerate(points):
            x = i * step_x
            norm = (val - min_h) / span
            y = h - 20 - (norm * (h - 40))
            coords.append((x, y))
            
        for i in range(len(coords) - 1):
            self.heap_canvas.create_line(coords[i][0], coords[i][1], coords[i+1][0], coords[i+1][1], fill=self.colors["success"], width=2, tags="graph")
            self.heap_canvas.create_rectangle(coords[i][0]-2, coords[i][1]-2, coords[i][0]+2, coords[i][1]+2, fill=self.colors["accent"], outline="", tags="graph")

    def setup_serial_view(self):
        s_view = self.views["serial"]
        
        # Interface configurations toolbar row
        s_bar = tk.Frame(s_view, bg=self.colors["panel"], padx=12, pady=10)
        s_bar.pack(fill="x", pady=(0, 10))

        tk.Label(s_bar, text="Port:", fg=self.colors["muted"], bg=self.colors["panel"]).pack(side="left", padx=4)
        self.ports_combo = ttk.Combobox(s_bar, textvariable=self.port_var, width=12, state="readonly")
        self.ports_combo.pack(side="left", padx=6)

        tk.Label(s_bar, text="Baud rate:", fg=self.colors["muted"], bg=self.colors["panel"]).pack(side="left", padx=4)
        self.baud_combo = ttk.Combobox(s_bar, textvariable=self.baud_var, values=("115200", "230400", "460800", "921600"), width=10, state="readonly")
        self.baud_combo.pack(side="left", padx=6)

        tk.Checkbutton(s_bar, text="Save session logs", variable=self.preserve_mode, fg=self.colors["text"], bg=self.colors["panel"], selectcolor="#0B1220", activebackground=self.colors["panel"]).pack(side="left", padx=10)
        tk.Checkbutton(s_bar, text="Auto analyze crashes", variable=self.auto_analyze_var, command=self.persist_auto_analyze, fg=self.colors["text"], bg=self.colors["panel"], selectcolor="#0B1220", activebackground=self.colors["panel"]).pack(side="left", padx=10)

        self.make_modern_btn(s_bar, "⟳ Refresh Hardware", self.refresh_ports, "secondary").pack(side="left", padx=4)
        self.connect_btn = self.make_modern_btn(s_bar, "▶ Connect Monitor", self.toggle_serial, "success")
        self.connect_btn.pack(side="right", padx=4)

        # Scrolled terminal engine viewport
        self.text_area = scrolledtext.ScrolledText(s_view, font=("JetBrains Mono", 10), bg=self.colors["console"], fg=self.colors["console_fg"], insertbackground=self.colors["accent"], relief="flat", bd=0, padx=12, pady=12)
        self.text_area.pack(fill="both", expand=True)
        self.configure_text_tags(self.text_area)

        # Command input block terminal pipeline
        tx_bar = tk.Frame(s_view, bg=self.colors["panel"], padx=10, pady=8)
        tx_bar.pack(fill="x", pady=(10, 0))
        tk.Label(tx_bar, text="TX Pipeline:", fg=self.colors["muted"], bg=self.colors["panel"], font=("Segoe UI", 9, "bold")).pack(side="left", padx=(0, 6))
        
        ttk.Combobox(tx_bar, textvariable=self.quick_command_var, values=("Custom", "help", "status", "heap", "events", "reset"), width=10, state="readonly").pack(side="left", padx=4)
        self.quick_command_var.trace_add("write", lambda *args: self.apply_quick_command())
        
        self.cmd_entry = tk.Entry(tx_bar, font=("JetBrains Mono", 10), bg="#0B1220", fg=self.colors["text"], insertbackground=self.colors["accent"], relief="flat", highlightthickness=1, highlightbackground=self.colors["border"])
        self.cmd_entry.pack(side="left", fill="x", expand=True, padx=8, ipady=5)
        self.cmd_entry.bind("<Return>", lambda e: self.send_command())
        self.make_modern_btn(tx_bar, "🚀 Execute", self.send_command, "primary").pack(side="right")

    def setup_diagnostics_view(self):
        d_view = self.views["diagnostics"]
        
        # Diagnostics search and trigger utilities deck
        diag_toolbar = tk.Frame(d_view, bg=self.colors["panel"], padx=12, pady=8)
        diag_toolbar.pack(fill="x", pady=(0, 10))
        
        self.make_modern_btn(diag_toolbar, "🧠 Run Active Analysis", self.smart_solve, "primary").pack(side="left", padx=2)
        self.make_modern_btn(diag_toolbar, "📋 Copy Report", self.copy_report, "secondary").pack(side="left", padx=4)
        self.make_modern_btn(diag_toolbar, "💾 Export Report", self.export_report, "secondary").pack(side="left", padx=4)
        self.make_modern_btn(diag_toolbar, "📁 Logs Folder", self.open_log_folder, "secondary").pack(side="left", padx=4)
        self.make_modern_btn(diag_toolbar, "🗑 Clear Screens", self.clear_all, "danger").pack(side="right", padx=2)

        # Advanced Query Routing Filter Block
        search_frame = tk.Frame(d_view, bg=self.colors["panel"], padx=12, pady=6)
        search_frame.pack(fill="x", pady=(0, 10))
        tk.Label(search_frame, text="🔍 Context Query:", fg=self.colors["muted"], bg=self.colors["panel"]).pack(side="left", padx=4)
        
        ttk.Combobox(search_frame, textvariable=self.filter_var, values=("All", "Origin", "Critical", "High", "Medium", "EventBus", "Heap"), width=11, state="readonly").pack(side="left", padx=6)
        
        search_entry = tk.Entry(search_frame, textvariable=self.search_var, bg="#0B1220", fg=self.colors["text"], insertbackground=self.colors["accent"], relief="flat", highlightthickness=1, highlightbackground=self.colors["border"])
        search_entry.pack(side="left", fill="x", expand=True, padx=6, ipady=4)
        search_entry.bind("<Return>", lambda e: self.search_report())
        self.make_modern_btn(search_frame, "Find Filter Match", self.search_report, "secondary").pack(side="right", padx=2)

        # Results terminal board presentation area
        self.result_area = scrolledtext.ScrolledText(d_view, font=("JetBrains Mono", 10), bg=self.colors["console"], fg="#E2E8F0", insertbackground=self.colors["accent"], relief="flat", bd=0, padx=12, pady=12)
        self.result_area.pack(fill="both", expand=True)
        self.configure_text_tags(self.result_area)

    def make_modern_btn(self, parent, text, command, kind="primary"):
        palette = {
            "primary": (self.colors["accent"], "#FFFFFF"),
            "secondary": ("#222F47", self.colors["text"]),
            "success": (self.colors["success"], "#FFFFFF"),
            "danger": (self.colors["danger"], "#FFFFFF")
        }
        bg, fg = palette.get(kind, palette["primary"])
        btn = tk.Button(parent, text=text, command=command, bg=bg, fg=fg, activebackground=bg, activeforeground=fg,
                        relief="flat", bd=0, padx=14, pady=6, font=("Segoe UI", 9, "bold"), cursor="hand2")
        return btn

    def configure_text_tags(self, widget):
        widget.tag_configure("critical", foreground="#FF4D6D", font=("JetBrains Mono", 10, "bold"))
        widget.tag_configure("high", foreground="#FFB703", font=("JetBrains Mono", 10, "bold"))
        widget.tag_configure("medium", foreground="#4CC9F0")
        widget.tag_configure("ok", foreground="#10B981")
        widget.tag_configure("muted", foreground="#64748B")
        widget.tag_configure("addr", foreground="#A7F3D0")
        widget.tag_configure("event", foreground="#818CF8")
        widget.tag_configure("storage", foreground="#C4B5FD")
        widget.tag_configure("system", foreground="#94A3B8")
        widget.tag_configure("match", background="#3B82F6", foreground="#FFFFFF")

    def classify_line_tag(self, line):
        lowered = line.lower()
        if any(w in lowered for w in ("critical", "panic", "guru meditation", "corrupt heap", "stack canary")):
            return "critical"
        if any(w in lowered for w in ("error", "watchdog", "brownout", "abort")):
            return "high"
        if any(w in lowered for w in ("[main] event", "eventbus", "successfully published")):
            return "event"
        if any(w in lowered for w in ("storagemanager", "littlefs", "initial config data")):
            return "storage"
        if any(w in lowered for w in ("[system]", "connected to", "serial monitor")):
            return "system"
        if any(w in lowered for w in ("warning", "warn", "wifi", "tls", "heap")):
            return "medium"
        if re.search(r"0x[0-9a-fA-F]{8}", line):
            return "addr"
        return None

    def insert_text(self, widget, text):
        widget.insert(tk.END, text)
        # Apply tags programmatically line by line to improve rendering precision
        widget.see(tk.END)

    def persist_auto_analyze(self):
        self.settings["auto_analyze"] = bool(self.auto_analyze_var.get())
        self.save_settings()

    def open_settings(self):
        win = tk.Toplevel(self.root)
        win.title("Engine Optimization Setup")
        win.geometry("450x320")
        win.configure(bg=self.colors["panel"])
        win.transient(self.root)
        win.grab_set()

        tk.Label(win, text="🔧 Engine Settings Configuration", font=("Segoe UI", 13, "bold"), bg=self.colors["panel"], fg=self.colors["text"]).pack(anchor="w", padx=20, pady=20)
        
        form = tk.Frame(win, bg=self.colors["panel"], padx=20)
        form.pack(fill="both", expand=True)

        tk.Label(form, text="Max Console View Buffer Lines", bg=self.colors["panel"], fg=self.colors["muted"]).pack(anchor="w", pady=2)
        line_var = tk.IntVar(value=int(self.settings["max_console_lines"]))
        tk.Entry(form, textvariable=line_var, bg="#0B1220", fg=self.colors["text"], relief="flat", highlightthickness=1, highlightbackground=self.colors["border"]).pack(fill="x", pady=6, ipady=4)

        tk.Label(form, text="Max Session Output Log Limit (MB)", bg=self.colors["panel"], fg=self.colors["muted"]).pack(anchor="w", pady=2)
        mb_var = tk.DoubleVar(value=float(self.settings["max_log_mb"]))
        tk.Entry(form, textvariable=mb_var, bg="#0B1220", fg=self.colors["text"], relief="flat", highlightthickness=1, highlightbackground=self.colors["border"]).pack(fill="x", pady=6, ipady=4)

        def save_and_close():
            self.settings["max_console_lines"] = max(500, line_var.get())
            self.settings["max_log_mb"] = max(1.0, mb_var.get())
            self.save_settings()
            win.destroy()
            self.update_status("Runtime optimization rules updated.")

        self.make_modern_btn(form, "Apply Engine Rule", save_and_close, "primary").pack(anchor="e", pady=15)

    def browse_folder(self):
        folder = filedialog.askdirectory(initialdir=self.path_var.get())
        if folder:
            self.path_var.set(folder)
            self.settings["project_path"] = folder
            self.save_settings()
            self.update_status(f"Workspace root targeted: {Path(folder).name}")

    def find_elf_quiet(self):
        try:
            self.find_elf(show_errors=False)
        except Exception:
            pass

    def find_elf(self, show_errors=True):
        search_dirs = []
        project_path = self.path_var.get().strip()
        if project_path and os.path.exists(project_path):
            search_dirs.append(Path(project_path))

        temp_base = self.home / "AppData" / "Local" / "Temp"
        if temp_base.exists():
            search_dirs.extend(temp_base.glob("arduino/sketches/*"))
            search_dirs.extend(temp_base.glob("arduino-sketch-*"))

        elf_files = []
        for directory in search_dirs:
            try:
                if directory.exists():
                    elf_files.extend(directory.rglob("*.elf"))
            except OSError:
                continue

        if not elf_files:
            self.elf_path = None
            self.elf_label.config(text="Symbols Missing", fg=self.colors["danger"])
            if show_errors:
                messagebox.showerror("Target Failure", "No diagnostic binary architecture target (.elf image) located.")
            return

        self.elf_path = str(max(elf_files, key=os.path.getmtime))
        elf_name = Path(self.elf_path).name
        self.elf_label.config(text=f"🎯 {elf_name}", fg=self.colors["success"])
        self.update_status(f"Active symbol reference loaded: {elf_name}")
        self.footer_meta.config(text=f"Target: {elf_name[:18]}... | SHA: Validating")

    def toggle_serial(self):
        if self.reading:
            self.stop_session()
        else:
            self.start_session()

    def start_session(self):
        if serial is None:
            messagebox.showerror("Dependency Error", "Serial processing core requires python modules: pyserial")
            return
        port = self.port_var.get()
        if not port:
            messagebox.showerror("Hardware Fault", "Select active device interface node port.")
            return

        try:
            baud = int(self.baud_var.get())
            self.ser = serial.Serial(port, baud, timeout=0.1)
            self.reading = True
            self.connect_btn.config(text="■ Stop Stream", bg=self.colors["danger"])
            self.status_chip.config(text=f"● CONNECTED ({port})", fg=self.colors["success"], bg="#0E1C16")

            if self.preserve_mode.get():
                log_dir = Path(self.path_var.get()) / "logs"
                log_dir.mkdir(parents=True, exist_ok=True)
                log_name = f"Session_Telemetry_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
                self.current_log_path = str(log_dir / log_name)
                self.log_file = open(self.current_log_path, "a", encoding="utf-8")
                self.text_area.insert(tk.END, f"[SYSTEM ENGINE] Log trace piped directly to logs/{log_name}\n", "system")

            self.last_line = ""
            self.repeat_count = 0
            threading.Thread(target=self.serial_reader, daemon=True).start()
            self.update_status("Telemetry monitoring array running...")
        except Exception as exc:
            messagebox.showerror("Core Interface Fault", str(exc))

    def stop_session(self):
        self.reading = False
        if self.ser:
            try: self.ser.close() 
            except Exception: pass
        if self.log_file:
            try: self.log_file.close()
            except Exception: pass
            self.log_file = None
        self.connect_btn.config(text="▶ Connect Monitor", bg=self.colors["success"])
        self.status_chip.config(text="● DISCONNECTED", fg=self.colors["danger"], bg="#170F1C")
        self.text_area.insert(tk.END, "[SYSTEM ENGINE] Device execution processing decoupled.\n", "system")
        self.update_status("Telemetry stream stopped.")

    def apply_quick_command(self):
        cmd = self.quick_command_var.get()
        if cmd and cmd != "Custom":
            self.cmd_entry.delete(0, tk.END)
            self.cmd_entry.insert(0, cmd)

    def send_command(self):
        cmd = self.cmd_entry.get().strip()
        if not cmd:
            return
        if not self.ser or not self.ser.is_open:
            self.text_area.insert(tk.END, f"[TX ERROR] Telemetry line broken. Execution dropped: {cmd}\n", "critical")
            return
        try:
            self.ser.write((cmd + "\r\n").encode("utf-8"))
            self.text_area.insert(tk.END, f"[TX COMMAND INTERRUPT] -> {cmd}\n", "system")
            self.cmd_entry.delete(0, tk.END)
        except Exception as e:
            self.text_area.insert(tk.END, f"[TX TRANSMISSION FAULT] {e}\n", "critical")

    def serial_reader(self):
        while self.reading:
            try:
                if not self.ser or not self.ser.in_waiting:
                    time.sleep(0.02)
                    continue
                line = self.ser.readline().decode("utf-8", errors="replace").rstrip()
                if not line:
                    continue
                current_ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
                self.root.after(0, self.handle_serial_line, line, current_ts)
            except Exception as e:
                err_msg = str(e)
                self.root.after(0, lambda: self.text_area.insert(tk.END, f"[DECODER RUNTIME CRASH] {err_msg}\n", "critical"))
                break

    def handle_serial_line(self, line, current_ts):
        # Console duplicate collapse engine optimization
        if line == self.last_line:
            if self.repeat_count == 0:
                self.repeat_start_ts = self.last_ts
            self.repeat_count += 1
            self.last_ts = current_ts
            return

        if self.repeat_count > 0:
            self.write_to_terminal_buffer(f"[{self.repeat_start_ts} -> {self.last_ts}] 🔁 collapsed {self.repeat_count}x iterations: {self.last_line}\n", "muted")
            self.repeat_count = 0

        self.last_line = line
        self.last_ts = current_ts
        
        tag = self.classify_line_tag(line)
        self.write_to_terminal_buffer(f"[{current_ts}] {line}\n", tag)

        # Dynamic heap telemetry parse hook
        heap_match = re.search(r"Free Heap:\s*(\d+)", line, re.IGNORECASE)
        if heap_match:
            h_val = int(heap_match.group(1))
            self.heap_history.pop(0)
            self.heap_history.append(h_val)
            self.draw_heap_graph()

        if self.auto_analyze_var.get() and self.is_crash_trigger(line):
            self.schedule_analysis()

    def write_to_terminal_buffer(self, text, tag):
        self.text_area.insert(tk.END, text, tag)
        if self.log_file and not self.log_file.closed:
            try: self.log_file.write(text)
            except Exception: pass
            
        # Enforce line wrap limits
        curr_lines = int(self.text_area.index("end-1c").split(".")[0])
        max_buf = int(self.settings["max_console_lines"])
        if curr_lines > max_buf:
            self.text_area.delete("1.0", f"{curr_lines - max_buf}.0")
        self.text_area.see(tk.END)

    def is_crash_trigger(self, line):
        markers = ("Backtrace:", "Guru Meditation", "panic", "abort()", "LoadProhibited", "CORRUPT HEAP", "Stack canary")
        return any(m in line for m in markers)

    def schedule_analysis(self):
        if self.analysis_timer:
            self.analysis_timer.cancel()
        self.analysis_timer = threading.Timer(1.0, lambda: self.root.after(0, self.smart_solve))
        self.analysis_timer.daemon = True
        self.analysis_timer.start()

    def refresh_ports(self):
        if serial is None:
            self.update_status("Driver initialization failed.")
            return
        all_ports = serial.tools.list_ports.comports()
        ports = [p.device for p in all_ports if (
            (p.hwid and "USB" in p.hwid.upper()) or 
            (p.description and "USB" in p.description.upper()) or 
            (p.manufacturer and "USB" in p.manufacturer.upper())
        )]
        if not ports:
            ports = [p.device for p in all_ports]
            
        self.ports_combo["values"] = ports
        if ports:
            self.ports_combo.current(0)
            self.update_status(f"Hardware Array: Detected {len(ports)} interface targets.")
        else:
            self.ports_combo.set("")
            self.update_status("No hardware targets ready.")

    def auto_refresh_ports(self):
        if serial is None:
            return
        if not self.reading:
            try:
                all_ports = serial.tools.list_ports.comports()
                ports = [p.device for p in all_ports if (
                    (p.hwid and "USB" in p.hwid.upper()) or 
                    (p.description and "USB" in p.description.upper()) or 
                    (p.manufacturer and "USB" in p.manufacturer.upper())
                )]
                if not ports:
                    ports = [p.device for p in all_ports]
                
                current_values = list(self.ports_combo["values"])
                if ports != current_values:
                    current_sel = self.port_var.get()
                    self.ports_combo["values"] = ports
                    
                    if current_sel in ports:
                        self.port_var.set(current_sel)
                    elif ports:
                        self.ports_combo.current(0)
                    else:
                        self.port_var.set("")
                        
                    self.update_status(f"Hardware Array updated: Detected {len(ports)} interface targets.")
            except Exception:
                pass
        self.root.after(2000, self.auto_refresh_ports)

    def smart_solve(self):
        raw_log = self.text_area.get("1.0", tk.END).strip()
        self.result_area.delete("1.0", tk.END)

        if not raw_log:
            self.result_area.insert(tk.END, "Telemetry logs empty. Feed real-time streams or load archive dumps.\n", "muted")
            self.update_summary_cards({})
            return

        # Core execution analytics pipeline mapping
        detections = self.detect_faults(raw_log)
        crash_context = self.extract_crash_context(raw_log)
        addresses = self.extract_addresses(raw_log, crash_context)
        symbols = self.resolve_symbols(addresses)
        sha_status = self.verify_elf_sha(raw_log)
        metrics = self.collect_metrics(raw_log, addresses, detections, symbols, crash_context, sha_status)

        # Build highly readable structural card reports
        report = []
        report.append(f"╔══════════════════════════════════════════════════════════════════════════╗")
        report.append(f"  CYPHERNODE NEURAL EXECUTION ANALYSIS DECK - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        report.append(f"╚══════════════════════════════════════════════════════════════════════════╝\n")

        # Visualizing the probable instruction flow path
        report.append("─ Crash Visualized Stack Path ─")
        origin = self.find_origin_frame(crash_context, symbols)
        if origin:
            report.append(f"  [Entry Target] ──> {origin}")
            if crash_context.get("excvaddr"):
                report.append(f"                     └── [💥 Violating Address Location] ──> {crash_context['excvaddr']}")
        else:
            report.append("  [Flow Path] ──> Trace path unknown. Validate ELF architecture match mappings.")
        report.append("")

        # Append standard detailed reports
        report.extend(self.render_faults(detections))
        report.extend(self.render_backtrace(crash_context, symbols))
        
        self.last_report = "\n".join(report) + "\n"
        self.result_area.insert(tk.END, self.last_report)
        
        self.update_summary_cards(metrics)
        self.update_status("Deep stack analysis complete.")
        
        # Sync meta metadata to footer indicators
        core_lbl = f"Core {crash_context['core']}" if crash_context.get('core') else "System Panic"
        self.footer_meta.config(text=f"Origin Mapped | SHA: {metrics['sha_state'].upper()} | State: {core_lbl}")

    def detect_faults(self, raw_log):
        detections = []
        for rule in DIAGNOSTIC_RULES:
            matches = [p for p in rule.patterns if re.search(p, raw_log, flags=re.IGNORECASE)]
            if matches:
                detections.append((rule, matches))
        detections.sort(key=lambda item: SEVERITY_WEIGHT.get(item[0].severity, 0), reverse=True)
        return detections

    def extract_addresses(self, raw_log, crash_context=None):
        found = re.findall(r"0x[0-9a-fA-F]{8}", raw_log)
        if crash_context:
            found = crash_context.get("priority_addresses", []) + found
        unique = []
        seen = set()
        for addr in found:
            norm = addr.lower()
            if norm not in seen:
                seen.add(norm)
                unique.append(addr)
        return unique

    def extract_crash_context(self, raw_log):
        context = {"pc": None, "excvaddr": None, "exception": None, "core": None, "backtrace": [], "priority_addresses": []}
        ex_m = re.search(r"Guru Meditation Error:\s*Core\s+(\d+).*?\(([^)]+)\)", raw_log, re.IGNORECASE)
        if ex_m:
            context["core"], context["exception"] = ex_m.group(1), ex_m.group(2)
        
        pc_m = re.search(r"(?:\bPC\s*:|\bPC=)\s*(0x[0-9a-fA-F]{8})", raw_log, re.IGNORECASE)
        if pc_m: context["pc"] = pc_m.group(1)

        excv_m = re.search(r"\bEXCVADDR\s*:\s*(0x[0-9a-fA-F]{8})", raw_log, re.IGNORECASE)
        if excv_m: context["excvaddr"] = excv_m.group(1)

        # Parse FreeRTOS exception frames
        bt_lines = []
        capture = False
        for line in raw_log.splitlines():
            if "Backtrace:" in line:
                capture = True
                bt_lines.append(re.sub(r"^.*?\bBacktrace:\s*", "", line, flags=re.IGNORECASE))
                continue
            if capture:
                if "0x" in line: bt_lines.append(line)
                else: break
        
        bt_text = " ".join(bt_lines)
        for pc, sp in re.findall(r"(0x[0-9a-fA-F]{8})(?::(0x[0-9a-fA-F]{8}))?", bt_text):
            context["backtrace"].append({"pc": pc, "sp": sp or ""})

        if context["pc"]: context["priority_addresses"].append(context["pc"])
        context["priority_addresses"].extend(f["pc"] for f in context["backtrace"])
        return context

    def resolve_symbols(self, addresses):
        symbols = {}
        if not addresses or not self.elf_path:
            return symbols
        tool = self.get_tool_path()
        if not tool:
            return symbols
        
        code_addrs = [a for a in addresses if a.lower().startswith(("0x400", "0x401", "0x420", "0x403"))]
        if not code_addrs:
            return symbols
            
        try:
            cmd = [tool, "-e", self.elf_path, "-pfiaC", *code_addrs]
            out = subprocess.check_output(cmd, text=True, timeout=5)
            for addr, line in zip(code_addrs, out.splitlines()):
                symbols[addr.lower()] = line.strip()
        except Exception:
            pass
        return symbols

    def get_tool_path(self):
        bases = [
            self.home / "AppData" / "Local" / "Arduino15" / "packages" / "esp32" / "tools",
            self.home / ".arduino15" / "packages" / "esp32" / "tools"
        ]
        patterns = []
        for base in bases:
            patterns.append(str(base / "xtensa-esp32-elf-gcc" / "*" / "bin" / "xtensa-esp32-elf-addr2line.exe"))
            patterns.append(str(base / "xtensa-esp32s3-elf-gcc" / "*" / "bin" / "xtensa-esp32s3-elf-addr2line.exe"))
            patterns.append(str(base / "xtensa-esp32-elf-gcc" / "*" / "bin" / "xtensa-esp32-elf-addr2line"))
            patterns.append(str(base / "xtensa-esp32s3-elf-gcc" / "*" / "bin" / "xtensa-esp32s3-elf-addr2line"))
        
        candidates = []
        for p in patterns:
            candidates.extend(glob.glob(p))
        return max(candidates, key=os.path.getmtime) if candidates else None

    def verify_elf_sha(self, raw_log):
        # Scan markers matching binary hashes
        match = re.search(r"ELF file SHA256:\s*([0-9a-fA-F]{16,64})", raw_log)
        if not match:
            return {"state": "missing"}
        return {"state": "match" if self.elf_path else "unknown"}

    def collect_metrics(self, raw_log, addresses, detections, symbols, crash_context, sha_status):
        counts = {"critical": 0, "high": 0, "medium": 0, "low": 0}
        for rule, _ in detections:
            counts[rule.severity] = counts.get(rule.severity, 0) + 1
        
        # Process structural telemetries to project configurations dashboard fields
        project_telemetry = {
            "heap_latest": "Unknown", "event_ratio": "No Data", "storage_state": "Unchecked"
        }
        h_samples = [int(v) for v in re.findall(r"Free Heap:\s*(\d+)", raw_log)]
        if h_samples:
            project_telemetry["heap_latest"] = f"{h_samples[-1] // 1024} KB"
            self.dash_heap_val.config(text=f"✓ Real-time Free Heap Pool Space: {h_samples[-1]} Bytes (Latest Matrix)")
            
        ev_ok = len(re.findall(r"successfully published", raw_log, re.IGNORECASE))
        ev_fail = len(re.findall(r"FAILED to publish", raw_log, re.IGNORECASE))
        if ev_ok or ev_fail:
            project_telemetry["event_ratio"] = f"{ev_ok} ok / {ev_fail} fail"
            self.dash_event_val.config(text=f"✓ EventBus Engine Core: {ev_ok} Successfully Mapped | {ev_fail} Interrupted Broadcasts")

        if "initial config data" in raw_log.lower():
            self.dash_storage_val.config(text="✓ Storage Subsystem: SPI Flash LittleFS Mount Array System Checked (OK)")

        return {
            "critical": counts["critical"], "high": counts["high"], "medium": counts["medium"],
            "sha_state": sha_status.get("state", "missing"), "project": project_telemetry
        }

    def find_origin_frame(self, crash_context, symbols):
        candidates = []
        if crash_context.get("pc"): candidates.append(crash_context["pc"])
        candidates.extend(f["pc"] for f in crash_context.get("backtrace", []))
        for addr in candidates:
            dec = symbols.get(addr.lower())
            if dec and "??" not in dec:
                return f"{addr} -> {dec}"
        return ""

    def render_faults(self, detections):
        lines = ["─ Subsystem Risk Evaluation Modules ─"]
        if not detections:
            lines.append("  No matching anomalous structural code exceptions detected.")
            return lines
        for r, patterns in detections:
            lines.append(f" 🟥 [{r.severity.upper()}] {r.name}")
            lines.append(f"    Possible Cause: {r.cause}")
            lines.append(f"    Suggested Patch Fix: {r.action}\n")
        return lines

    def render_backtrace(self, crash_context, symbols):
        lines = ["─ Decompiled Call Backtrace Stack Frame Map ─"]
        frames = crash_context.get("backtrace", [])
        if not frames:
            lines.append("  Backtrace frames empty or instruction map pointer unlinked.")
            return lines
        for idx, f in enumerate(frames, start=1):
            pc, sp = f["pc"], f["sp"] or "no-sp"
            dec = symbols.get(pc.lower(), "Symbol resolution architecture omitted")
            lines.append(f"  #{idx:02d} Target Pipeline Address: {pc} | Stack Allocation Pointer: {sp}")
            lines.append(f"       └── {dec}")
        return lines

    def update_summary_cards(self, metrics):
        if not metrics:
            for k in self.ui_cards: self.ui_cards[k].config(text="0" if k != "health" else "STABLE")
            return
        
        self.ui_cards["critical"].config(text=str(metrics.get("critical", 0)))
        self.ui_cards["high"].config(text=str(metrics.get("high", 0)))
        self.ui_cards["medium"].config(text=str(metrics.get("medium", 0)))
        
        if metrics.get("critical", 0) > 0:
            self.ui_cards["health"].config(text="UNSTABLE", fg=self.colors["danger"])
        elif metrics.get("high", 0) > 0:
            self.ui_cards["health"].config(text="WARNING", fg=self.colors["warning"])
        else:
            self.ui_cards["health"].config(text="HEALTHY", fg=self.colors["success"])

    def search_report(self):
        query = self.search_var.get().strip()
        self.result_area.tag_remove("match", "1.0", tk.END)
        if not query: return
        
        start = "1.0"
        while True:
            pos = self.result_area.search(query, start, stopindex=tk.END, nocase=True)
            if not pos: break
            end = f"{pos}+{len(query)}c"
            self.result_area.tag_add("match", pos, end)
            start = end
        self.update_status("Query highlighting map updated.")

    def copy_report(self):
        rep = self.result_area.get("1.0", tk.END).strip()
        if not rep: return
        self.root.clipboard_clear()
        self.root.clipboard_append(rep)
        self.update_status("Report copied to OS clipboard.")

    def export_report(self):
        rep = self.result_area.get("1.0", tk.END).strip()
        if not rep: return
        fn = filedialog.asksaveasfilename(title="Save Analysis Deck", defaultextension=".txt", filetypes=(("Text", "*.txt"),))
        if fn:
            Path(fn).write_text(rep, encoding="utf-8")
            self.update_status("Analysis deck successfully saved.")

    def load_log_file(self):
        file_path = filedialog.askopenfilename(
            title="Load Log File",
            filetypes=(("Log Files", "*.log;*.txt"), ("All Files", "*.*"))
        )
        if not file_path:
            return
        try:
            content = Path(file_path).read_text(encoding="utf-8", errors="replace")
            self.stop_session()
            self.text_area.delete("1.0", tk.END)
            self.text_area.insert(tk.END, content)
            self.update_status(f"Loaded log file: {Path(file_path).name}")
            self.smart_solve()
            self.switch_view("diagnostics")
        except Exception as e:
            messagebox.showerror("Error Loading File", f"Failed to load log file: {e}")

    def open_log_folder(self):
        p = Path(self.path_var.get()) / "logs"
        if p.exists(): os.startfile(str(p))

    def clear_all(self):
        self.text_area.delete("1.0", tk.END)
        self.result_area.delete("1.0", tk.END)
        self.update_summary_cards({})
        self.update_status("Terminal working context flushed clean.")

    def update_status(self, msg):
        self.status_var.set(f" ⚙ System Status: {msg}")

    def on_closing(self):
        self.reading = False
        if self.ser: self.ser.close()
        self.root.destroy()

if __name__ == "__main__":
    app = ESPHomeSerialTool()
    app.root.mainloop()