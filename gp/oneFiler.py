"""
A simple script that walks through the project and concatenates allowed text files.

Usage:
    python3 oneFiler.py /path/to/project

The output will be saved in the current directory as "oneFile_project.txt"."
"""

import os
import datetime

# --- CONFIGURATION ---
OUTPUT_FILE = "oneFile_project.txt"

# Directories to entirely skip (Prevents scanning heavy/useless folders)
IGNORE_DIRS = {
    '.git', 'node_modules', 'venv', '.venv', '__pycache__', 
    'build', 'out', 'work', 'sim_build', 'xsim.dir'
}

# Text files that we STILL want to skip (Large/generated text files)
IGNORE_EXTS = {
    '.log', '.csv', '.tsv', '.min.js', '.min.css', '.lock'
}
# ---------------------

def is_text_file(file_path):
    """
    Reads the first 1024 bytes of a file. 
    If it contains a null byte (\x00), it's considered binary and skipped.
    """
    try:
        with open(file_path, 'rb') as f:
            chunk = f.read(1024)
        if b'\0' in chunk:
            return False
        return True
    except Exception:
        return False

def get_tree_structure(root_dir):
    """Generates a string representation of the directory tree."""
    tree_str = ""
    for root, dirs, files in os.walk(root_dir):
        # Modify dirs in-place to skip ignored directories
        dirs[:] = [d for d in dirs if d not in IGNORE_DIRS]
        dirs.sort()
        files.sort()
        
        level = root.replace(root_dir, '').count(os.sep)
        indent = ' ' * 4 * level
        folder_name = os.path.basename(root)
        
        if level == 0:
            tree_str += f"{folder_name}/\n"
        else:
            tree_str += f"{indent}{folder_name}/\n"
            
        sub_indent = ' ' * 4 * (level + 1)
        for f in files:
            _, ext = os.path.splitext(f)
            
            # Skip the output file, the script itself, and ignored extensions
            if f == OUTPUT_FILE or f == os.path.basename(__file__) or ext.lower() in IGNORE_EXTS:
                continue
                
            file_path = os.path.join(root, f)
            # Only add to tree if it passes the binary check
            if is_text_file(file_path):
                tree_str += f"{sub_indent}{f}\n"
                
    return tree_str

def create_bundle(root_dir):
    """Walks through the project and concatenates allowed text files."""
    total_files_processed = 0
    skipped_files = 0
    
    with open(OUTPUT_FILE, 'w', encoding='utf-8') as outfile:
        # 1. Write the metadata and tree structure
        outfile.write(f"Project Bundle Generated: {datetime.datetime.now()}\n")
        outfile.write("=" * 50 + "\n")
        outfile.write("DIRECTORY STRUCTURE (Filtered):\n")
        outfile.write("=" * 50 + "\n\n")
        
        print("Building directory tree...")
        tree = get_tree_structure(root_dir)
        outfile.write(tree)
        outfile.write("\n\n")
        
        outfile.write("=" * 50 + "\n")
        outfile.write("FILE CONTENTS:\n")
        outfile.write("=" * 50 + "\n\n")

        # 2. Walk through and append file contents
        print("Processing files...")
        for root, dirs, files in os.walk(root_dir):
            # Skip ignored directories
            dirs[:] = [d for d in dirs if d not in IGNORE_DIRS]
            
            for file in files:
                _, ext = os.path.splitext(file)
                
                # Skip based on name or extension first
                if file == OUTPUT_FILE or file == os.path.basename(__file__) or ext.lower() in IGNORE_EXTS:
                    continue
                    
                file_path = os.path.join(root, file)
                relative_path = os.path.relpath(file_path, root_dir)
                
                # THEN do the binary check
                if not is_text_file(file_path):
                    skipped_files += 1
                    continue
                
                # 3. Read and append the file
                try:
                    with open(file_path, 'r', encoding='utf-8') as infile:
                        content = infile.read()
                        
                    outfile.write(f"\n{'=' * 60}\n")
                    outfile.write(f"--- File: {relative_path} ---\n")
                    outfile.write(f"{'=' * 60}\n\n")
                    outfile.write(content)
                    outfile.write("\n")
                    
                    total_files_processed += 1
                    
                except UnicodeDecodeError:
                    # Fallback catch: some files have no null bytes but use weird encodings
                    skipped_files += 1
                    print(f"Skipped (Decode Error during full read): {relative_path}")
                except Exception as e:
                    print(f"Error reading {relative_path}: {e}")

    print(f"\n✅ Success!")
    print(f"Bundled {total_files_processed} text files into '{OUTPUT_FILE}'.")
    print(f"Automatically skipped {skipped_files} binary/unreadable files.")

if __name__ == "__main__":
    current_directory = os.getcwd()
    print(f"Starting bundling process in: {current_directory}...")
    create_bundle(current_directory)