#!/bin/bash
# unified linux application project
# main script: .tar to .ULP
clsjunk() {
    rm -rf "$workdir_temp"
}
#trap clsjunk EXIT
echo "The Unified Linux Application Project"
echo "Main Script: tarball to ULP"
echo "Please input your app's tarball directory"
read -re tarball_main
echo "$tarball_main is your app's tarball"
if [[ ! -f "$tarball_main" ]]; then
    echo "FATAL ERROR: File does not exist."
    exit 1
fi
workdir_temp="/tmp/ulp-workdir"
mkdir -p "$workdir_temp"
cd "$workdir_temp" || {
    echo "FATAL ERROR: Cannot cd into $workdir_temp"
    exit 1
}
mkdir -p extract
mkdir -p compress
mkdir -p exec
mkdir -p libs
extract_dir="$workdir_temp"/extract
compress_dir="$workdir_temp"/compress
exec_dir="$workdir_temp"/exec
lib_dir="$workdir_temp"/libs
# Check how many top-level entries the tarball has
top_level_count=$(tar -tf "$tarball_main" | awk -F/ '{print $1}' | uniq | wc -l)

if [[ $top_level_count -eq 1 ]]; then
    # Only one top-level folder, strip it
    tar -xvf "$tarball_main" -C "$extract_dir" --strip-components=1
else
    # Multiple files/folders at top-level, extract as-is
    tar -xvf "$tarball_main" -C "$extract_dir"
fi
echo "Your tarball has been extracted."
# search recursively for executables in the extract directory
executable_list=()
while IFS= read -r file; do
    executable_list+=("$file")
done < <(find "$extract_dir" -type f -executable)

# check if we found any executables
if [[ ${#executable_list[@]} -eq 0 ]]; then
    echo "FATAL ERROR: No executables found in $extract_dir!"
    exit 1
fi

# display them with numbers
echo "Found executables:"
for i in "${!executable_list[@]}"; do
    printf "%d) %s\n" $((i+1)) "${executable_list[$i]}"
done

# prompt user to select the main executable
read -rp "Enter the number of the main executable: " choice

# basic validation
if ! [[ $choice =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#executable_list[@]} )); then
    echo "FATAL ERROR: Invalid choice."
    exit 1
fi

main_exec="${executable_list[$((choice-1))]}"
echo "You chose: $main_exec"
read -rp "Do you want to test the executable before continuing? [y/n]" test_exec_choice
if [[ "${test_exec_choice^^}" == "Y" || "${test_exec_choice^^}" == "YES" ]]; then
    echo "Testing executable before continuing"
    echo "This function hasn't been implemented yet. Sorry."
    echo "Done. Continuing."
else
    echo "Continuing without testing"
fi
ldd $main_exec | awk '/=>/ {print $1}' | grep -v '^libc\.so' > libs.txt
if command -v apt >/dev/null 2>&1; then
    echo "Found apt"
    PKG=apt
elif command -v dnf >/dev/null 2>&1; then
    echo "Found dnf"
    PKG=dnf
elif command -v pacman >/dev/null 2>&1; then
    echo "Found pacman"
    PKG=pacman
else
    echo "No known package manager found"
    echo "FATAL ERROR: No way to install packages."
    exit 1
fi

# Ensure the lookup tool exists
case $PKG in
    apt)
        if ! command -v apt-file >/dev/null 2>&1; then
            echo "apt-file not found. Installing..."
            sudo apt update
            sudo apt install -y apt-file
            sudo apt-file update
        fi
        ;;
    dnf)
        if ! command -v dnf >/dev/null 2>&1; then
            echo "dnf not found. Cannot continue."
            exit 1
        fi
        if ! rpm -q dnf-plugins-core >/dev/null 2>&1; then
            echo "Installing dnf-plugins-core..."
            sudo dnf install -y dnf-plugins-core
        fi
        ;;
    pacman)
        if ! command -v pacman >/dev/null 2>&1; then
            echo "pacman not found. Cannot continue."
            exit 1
        fi
        if ! pacman -Qi pacman-contrib >/dev/null 2>&1; then
            echo "Installing pacman-contrib for 'pacman -F'..."
            sudo pacman -S --noconfirm pacman-contrib
        fi
        ;;
    *)
        echo "Unknown package manager: $PKG. Cannot install lookup tool."
        exit 1
        ;;
esac
if file "$main_exec" | grep -q "statically linked"; then
    echo "$main_exec is statically linked, no external libs needed."
    > libs.txt
else
    ldd "$main_exec" | awk '/=>/ {print $1}' | grep -v '^libc\.so' > libs.txt
fi


# Populate required_packages
required_packages=()
while read lib; do
    case $PKG in
        apt)
            pkg=$(apt-file search "$lib" | cut -d: -f1 | head -n1)
            ;;
        dnf)
            pkg=$(dnf provides "*$lib" | head -n1 | awk '{print $1}')
            ;;
        pacman)
            pkg=$(pacman -F "$lib" | head -n1 | awk '{print $1}')
            ;;
        *)
            pkg="UNKNOWN"
            ;;
    esac
    [[ $pkg != "UNKNOWN" ]] && required_packages+=("$pkg")
    echo "$lib => $pkg"
done < libs.txt

# Deduplicate package names (optional but nice)
required_packages=($(printf "%s\n" "${required_packages[@]}" | sort -u))
# files to output
apt_file="required_apt.txt"
dnf_file="required_dnf.txt"
pacman_file="required_pacman.txt"

> "$apt_file" "$dnf_file" "$pacman_file"  # clear them first

while read lib; do
    # Ubuntu/Debian
    pkg=$(apt-file search "$lib" 2>/dev/null | cut -d: -f1 | head -n1)
    [[ -n "$pkg" ]] && echo "$pkg" >> "$apt_file"

    # Fedora
    pkg=$(dnf provides "*$lib" 2>/dev/null | head -n1 | awk '{print $1}')
    [[ -n "$pkg" ]] && echo "$pkg" >> "$dnf_file"

    # Arch
    pkg=$(pacman -F "$lib" 2>/dev/null | head -n1 | awk '{print $1}')
    [[ -n "$pkg" ]] && echo "$pkg" >> "$pacman_file"
done < libs.txt

# Deduplicate files
for f in "$apt_file" "$dnf_file" "$pacman_file"; do
    sort -u -o "$f" "$f"
done


perm_workdir="$HOME/ULP-Perm-workdir"
mkdir -p "$perm_workdir"

mv required_apt.txt required_dnf.txt required_pacman.txt "$perm_workdir/"
echo "Package lists moved to $perm_workdir"
echo "Generating ULP"
cp -a "$extract_dir/." "$compress_dir/"
cd $compress_dir
mkdir -p ulp_libs
cd ulp_libs
cp "$perm_workdir/required_apt.txt" "$compress_dir/ulp_libs"
cp "$perm_workdir/required_dnf.txt" "$compress_dir/ulp_libs"
cp "$perm_workdir/required_pacman.txt" "$compress_dir/ulp_libs"
touch libinst.sh
cat > "$compress_dir/ulp_libs/libinst.sh" <<'EOF'
#!/bin/bash

# Auto-install required libraries for this ULP
if command -v apt >/dev/null 2>&1; then
    echo "Found apt"
    PKG=apt
elif command -v dnf >/dev/null 2>&1; then
    echo "Found dnf"
    PKG=dnf
elif command -v pacman >/dev/null 2>&1; then
    echo "Found pacman"
    PKG=pacman
else
    echo "No known package manager found"
    echo "FATAL ERROR: No way to install packages."
    exit 1
fi

APT_FILE="$PWD/required_apt.txt"
DNF_FILE="$PWD/required_dnf.txt"
PACMAN_FILE="$PWD/required_pacman.txt"

install_packages() {
    local pkg_list="$1"
    local cmd="$2"
    if [ -f "$pkg_list" ] && [ -s "$pkg_list" ]; then
        echo "Installing packages from $pkg_list..."
        sudo $cmd $(<"$pkg_list")
    else
        echo "No packages to install for $PKG or file missing: $pkg_list"
    fi
}

case $PKG in
    apt)
        install_packages "$APT_FILE" "apt install -y"
        ;;
    dnf)
        install_packages "$DNF_FILE" "dnf install -y"
        ;;
    pacman)
        install_packages "$PACMAN_FILE" "pacman -S --noconfirm"
        ;;
    *)
        echo "Unsupported package manager: $PKG. Cannot install packages."
        exit 1
        ;;
esac
EOF

chmod +x "$compress_dir/ulp_libs/libinst.sh"
echo "libinst.sh generated and ready to use!"
touch run.sh
# Convert main_exec to point to compress_dir
main_exec_compress="${main_exec/#$extract_dir/$compress_dir}"

echo "Main executable inside compress_dir will be: $main_exec_compress"
# Save the main executable path for run.sh
echo "$main_exec_compress" > "$compress_dir/ulp_main_exec.txt"
cat > "$compress_dir/run.sh" <<'EOF'
#!/bin/bash
mkdir -p "$HOME/.ulp
