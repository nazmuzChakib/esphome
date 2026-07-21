import os
import sys
import subprocess

def check_flutter_installed():
    """Checks if Flutter is installed and available in the PATH."""
    try:
        # Run flutter --version to verify installation
        subprocess.run(["flutter", "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False

def build_apk(verbose=False):
    """CDs into frontend folder and triggers compile verbose logs."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # Project root is parent of utils/tools directory
    project_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
    frontend_dir = os.path.join(project_root, "frontend")

    if not os.path.exists(frontend_dir):
        print(f"Error: Frontend directory not found at: {frontend_dir}")
        sys.exit(1)

    if not check_flutter_installed():
        print("Error: Flutter is not installed or not found in system PATH.")
        sys.exit(1)

    print("=== Initiating ESPHome Client App Compilation ===")
    print(f"Project Target Path: {frontend_dir}")
    print("Mode: Release APK")
    
    # Construct flutter build command
    command = ["flutter", "build", "apk", "--release"]
    if verbose:
        print("Logging Mode: VERBOSE enabled (-v/--verbose)")
        command.append("-v")
    else:
        print("Logging Mode: STANDARD (use -v or --verbose for full compiler diagnostics)")

    try:
        # Run process and pipe standard output to console in real-time
        # Working directory set to frontend
        process = subprocess.Popen(
            command,
            cwd=frontend_dir,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )

        # Print outputs in real time
        for line in process.stdout:
            print(line, end="")

        process.wait()

        if process.returncode == 0:
            print("\n=== SUCCESS: Flutter APK built successfully! ===")
            apk_path = os.path.join(frontend_dir, "build", "app", "outputs", "flutter-apk", "app-release.apk")
            print(f"Target Output Location: {apk_path}")
        else:
            print(f"\n=== FAILURE: Flutter compiler exited with code {process.returncode} ===")
            sys.exit(process.returncode)

    except KeyboardInterrupt:
        print("\n=== WARN: Compilation interrupted by user ===")
        sys.exit(1)
    except Exception as e:
        print(f"\nError executing build command: {str(e)}")
        sys.exit(1)

if __name__ == "__main__":
    # Check for verbose args
    is_verbose = False
    if len(sys.argv) > 1:
        args = sys.argv[1:]
        if "-v" in args or "--verbose" in args:
            is_verbose = True
            
    build_apk(verbose=is_verbose)
