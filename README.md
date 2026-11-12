# BloodHound Community Edition (CE) Auto-Setup & Management

An automated, robust, and clean setup script for deploying and managing **BloodHound Community Edition (CE)** on Linux (Kali Linux, Ubuntu, Debian, etc.).

> **Official Documentation:** [BloodHound Community Edition Quickstart](https://bloodhound.specterops.io/get-started/quickstart/community-edition-quickstart)  
> **Source Repository:** [SpecterOps/bloodhound-cli](https://github.com/SpecterOps/bloodhound-cli)

---

## ⚡ Quick Start
```bash
git clone https://github.com/cybr-ad/bloodhound-setup.git
chmod +x bloodhound-setup.sh
sudo ./bloodhound-setup.sh
```

## 🚀 Key Features

* **Complete Prerequisite Management**: Automatically checks and installs Docker Engine, Docker Compose v2, `wget`, `curl`, `tar`, and `xdg-utils`.
* **Hardware & Port Verification**: Checks CPU cores, RAM (warns if < 8 GB to avoid Neo4j OOM exit code 137), free disk space, and port 8080 conflicts.
* **Architecture Detection**: Supports both `amd64` (x86_64) and `arm64` (aarch64) systems.
* **Clean Installation**: Downloads the latest official release, extracts cleanly, and automatically removes the downloaded `.tar.gz` archive.
* **Global Terminal Access**: Creates system links in `/usr/local/bin` and `/usr/bin` so commands work from **any** terminal directory.
* **Interactive Graphical Prompt**: Asks if you want a graphical install (`./bloodhound-cli install`) to spin up Web UI containers, or just set up the CLI.
* **Complete Uninstaller**: Fully tears down containers, removes persistent database volumes, deletes configurations, and purges system links with `--uninstall`.

---

## 💻 How to Use (Example Commands)

### 1. Launching the Graphical Web UI
You can open the BloodHound CE Web UI from any terminal:

```bash
# Opens http://127.0.0.1:8080/ui/login in your default browser
bloodhound-gui
```
*Or use the unified shortcut:*
```bash
bloodhound
```

* **Web UI URL:** `http://127.0.0.1:8080/ui/login`
* **Default Username:** `admin`
* **Get Default Password:**
  ```bash
  bloodhound-cli config get default_password
  ```

---

### 2. Service & Container Management
Manage your BloodHound instance using `bloodhound-cli`:

| Task | Command |
|---|---|
| **Check Running Services** | `bloodhound-cli running` |
| **Check Installation & UI Health** | `sudo ./bloodhound-setup.sh --status` |
| **View Live Container Logs** | `bloodhound-cli logs -f` |
| **Start BloodHound Containers** | `bloodhound-cli up` |
| **Stop BloodHound Containers** | `bloodhound-cli down` |
| **Reset Administrator Password** | `bloodhound-cli resetpwd` |

---

### 3. Collecting & Ingesting Attack Path Data

#### A. Active Directory Collection (SharpHound - Windows)
Run on a domain-joined Windows host:
```cmd
SharpHound.exe -c All --zipfilename DomainData.zip
```

#### B. Active Directory Collection (bloodhound-python - Linux)
Run from Kali or any Linux machine:
```bash
bloodhound-python -d domain.local -u 'Administrator' -p 'Password123' -gc dc.domain.local -c All -ns 10.0.0.1
```

#### C. Azure / Microsoft Entra ID Collection (AzureHound)
```bash
azurehound -u "user@tenant.onmicrosoft.com" -p "Password123" --tenant "TENANT_ID" list -o azure.json
```

#### Ingesting Files into the Web UI:
1. Log in to `http://127.0.0.1:8080/ui/login`.
2. Click the **Upload** icon on the right sidebar.
3. Drag and drop your `.zip` (SharpHound) or `.json` (AzureHound) file.
4. Once analysis completes, navigate to the **Explore** tab to query attack paths.

---

## 🗑️ Complete Uninstallation

To completely remove BloodHound CE, stop all containers, wipe database volumes, remove binaries, configuration files, and system links:

```bash
sudo ./bloodhound-setup.sh --uninstall
```

*(To remove without confirmation prompt, use: `sudo ./bloodhound-setup.sh --uninstall -y`)*

---

## 🛠️ CLI Options Reference

```text
Usage: sudo ./bloodhound-setup.sh [OPTIONS]

Options:
  -y, --yes          Non-interactive mode (auto-confirm all prompts)
  -u, --uninstall    Completely remove BloodHound CE, containers, volumes, and links
  -s, --status       Check the status of BloodHound CE services and containers
  -h, --help         Show help message and exit
```

---

## ❓ Troubleshooting & Tips

* **Out-of-Memory (OOM) Errors (Exit Code 137)**:  
  BloodHound CE runs Neo4j and PostgreSQL. Allocate at least **8 GB RAM** to your machine or VM.
* **Port 8080 Conflict**:  
  If port 8080 is in use by another service (e.g. Apache, Tomcat, Burp Suite), stop the competing service before running `bloodhound-cli up`.
* **Docker Permissions**:  
  The setup script automatically adds your non-root user to the `docker` group. If running `docker` without `sudo` gives a permission error, run `newgrp docker` or log out and back in.

