# Migration to Windows Development Environment Plan

## 🎯 **Objective**
Migrate FileCopier development from WSL/Claude Code to native Windows VS Code with Claude Code for production-realistic testing and deployment.

## 📋 **Prerequisites Check**
Before starting, verify you have:
- [ ] Windows 10/11 with Administrator access
- [ ] Internet connection for tool downloads
- [ ] At least 2GB free space on C: drive
- [ ] Current project backed up in WSL

---

## **Phase 1: Initial Repository Migration**

### **Step 1.1: Create Windows Development Structure**
```powershell
# Open Windows PowerShell as Administrator
# Create development directory structure
New-Item -Path "C:\Dev" -ItemType Directory -Force
New-Item -Path "C:\Dev\win_repos" -ItemType Directory -Force
```

### **Step 1.2: Copy Repository from WSL to Windows**
```powershell
# Method 1: Using robocopy (recommended - preserves attributes)
robocopy "\\wsl.localhost\Ubuntu\home\alexj\repos\forker" "C:\Dev\win_repos\forker" /E /COPYALL /R:3 /W:1

# Method 2: If robocopy fails, use PowerShell copy
Copy-Item "\\wsl.localhost\Ubuntu\home\alexj\repos\forker" "C:\Dev\win_repos\forker" -Recurse -Force
```

### **Step 1.3: Verify Repository Copy**
```powershell
cd C:\Dev\win_repos\forker
dir

# Check key files exist
Test-Path ".\Setup-TestingEnvironment.ps1"
Test-Path ".\development-plan.md"
Test-Path ".\modules\FileCopier"
Test-Path ".\.git"
```

### **Step 1.4: Test Repository Integrity**
```powershell
# Check if Git repository is intact
git status
git log --oneline -5

# If git repository is corrupted, we'll fix it in Phase 3
```

---

## **Phase 2: Windows Development Tools Installation**

### **Step 2.1: Install Git for Windows**
```powershell
# Option 1: Using Windows Package Manager (recommended)
winget install Git.Git

# Option 2: Manual installation
# Download from: https://git-scm.com/download/win
# Choose "Git for Windows" setup
# Use default settings during installation
```

### **Step 2.2: Install GitHub CLI**
```powershell
# Using winget
winget install GitHub.cli

# Verify installation
gh --version
```

### **Step 2.3: Install/Verify PowerShell 7+**
```powershell
# Check current PowerShell version
$PSVersionTable.PSVersion

# If version is less than 7.0, install PowerShell 7
winget install Microsoft.PowerShell

# Verify installation
pwsh --version
```

### **Step 2.4: Install Visual Studio Code (Native Windows)**
```powershell
# Install VS Code for Windows (not WSL extension)
winget install Microsoft.VisualStudioCode

# Verify installation
code --version
```

---

## **Phase 3: Git and GitHub Configuration**

### **Step 3.1: Configure Git Identity**
```powershell
cd C:\Dev\win_repos\forker

# Set Git identity (use your actual details)
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"

# Configure line endings for Windows
git config --global core.autocrlf true

# Check configuration
git config --list --global
```

### **Step 3.2: Authenticate with GitHub CLI**
```powershell
# Login to GitHub
gh auth login

# Follow the prompts:
# 1. Select "GitHub.com"
# 2. Select "HTTPS"
# 3. Select "Login with a web browser"
# 4. Copy the one-time code
# 5. Complete authentication in browser
```

### **Step 3.3: Verify Git Repository Status**
```powershell
cd C:\Dev\win_repos\forker

# Check repository status
git status
git remote -v

# If remote is missing, add it:
# git remote add origin https://github.com/YOUR_USERNAME/forker.git
```

### **Step 3.4: Test Git Operations**
```powershell
# Test basic Git operations
git fetch
git status
gh repo view
```

---

## **Phase 4: VS Code and Claude Code Setup**

### **Step 4.1: Launch Native Windows VS Code**
```powershell
# Open VS Code from Windows (not WSL)
cd C:\Dev\win_repos\forker
code .

# Verify you're in Windows VS Code (not WSL):
# - Check terminal: should show Windows paths
# - Check status bar: should not show "WSL: Ubuntu"
```

### **Step 4.2: Install Claude Code Extension**
```
1. Open Extensions panel (Ctrl+Shift+X)
2. Search for "Claude Code"
3. Install the official Claude Code extension by Anthropic
4. Restart VS Code if prompted
```

### **Step 4.3: Configure VS Code Terminal**
```json
// Add to VS Code settings.json (Ctrl+Shift+P → "Preferences: Open Settings (JSON)")
{
    "terminal.integrated.defaultProfile.windows": "PowerShell",
    "terminal.integrated.profiles.windows": {
        "PowerShell": {
            "source": "PowerShell",
            "args": ["-NoLogo"]
        },
        "PowerShell 7": {
            "path": "pwsh.exe",
            "args": ["-NoLogo"]
        }
    },
    "terminal.integrated.automationProfile.windows": {
        "path": "pwsh.exe"
    }
}
```

### **Step 4.4: Test Claude Code Integration**
```
1. Open integrated terminal (Ctrl+`)
2. Verify terminal shows: PS C:\Dev\win_repos\forker>
3. Test Claude Code can execute commands directly
4. Try running: Get-Location
```

---

## **Phase 5: PowerShell Environment Setup**

### **Step 5.1: Configure PowerShell Execution Policy**
```powershell
# Set execution policy for development
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Verify policy
Get-ExecutionPolicy -List
```

### **Step 5.2: Test Project Scripts**
```powershell
cd C:\Dev\win_repos\forker

# Test script execution (should work without bypass now)
.\Setup-TestingEnvironment.ps1 -CreateSampleFiles -SampleFileCount 20
```

### **Step 5.3: Verify Module Loading**
```powershell
# Test PowerShell module imports
Import-Module .\modules\FileCopier\Configuration.ps1 -Force
Import-Module .\modules\FileCopier\Logging.ps1 -Force

# Verify no errors occurred
```

---

## **Phase 6: Final Validation and Testing**

### **Step 6.1: Complete Environment Test**
```powershell
cd C:\Dev\win_repos\forker

# Run comprehensive setup
.\Setup-TestingEnvironment.ps1 -CreateSampleFiles -SampleFileCount 20

# Verify test environment created
Test-Path "C:\FileCopierTest"
dir C:\FileCopierTest
```

### **Step 6.2: Test Development Workflow**
```powershell
# Test Git workflow
git status
git add .
git commit -m "Test commit from Windows environment"
git push

# Test GitHub CLI
gh repo view
gh issue list
```

### **Step 6.3: Performance and Integration Test**
```powershell
cd C:\FileCopierTest

# Run quick tests to verify performance
.\Run-Tests.ps1 -Quick

# Test monitoring dashboard
# .\Start-Monitoring.ps1
```

### **Step 6.4: Validate Claude Code Integration**
```
1. In VS Code, test Claude Code can:
   - Execute PowerShell commands directly
   - Read and edit files
   - Run Git commands
   - Access file system operations
2. Verify no copy-paste workflow needed
3. Test integrated terminal responsiveness
```

---

## **Phase 7: Project Workspace Configuration**

### **Step 7.1: Create VS Code Workspace**
```json
// Save as: C:\Dev\win_repos\forker\forker-windows.code-workspace
{
    "folders": [
        {
            "path": "."
        }
    ],
    "settings": {
        "powershell.powerShellDefaultVersion": "PowerShell 7",
        "files.defaultLanguage": "powershell",
        "terminal.integrated.defaultProfile.windows": "PowerShell 7"
    },
    "extensions": {
        "recommendations": [
            "ms-vscode.powershell",
            "anthropic.claude-code"
        ]
    }
}
```

### **Step 7.2: Update Project Documentation**
```powershell
# Update development-plan.md with Windows-specific paths
# Update CLAUDE.md with Windows environment notes
# Create Windows-specific README if needed
```

---

## **🎯 Expected Outcomes**

### **Immediate Benefits:**
- ✅ **No more copy-paste workflow** - Direct command execution through Claude Code
- ✅ **Native Windows performance** - True file I/O speeds for large SVS files
- ✅ **Proper Windows paths** - Native `C:\` paths instead of WSL translations
- ✅ **Direct Git integration** - Seamless Git and GitHub CLI operations

### **Development Advantages:**
- ✅ **Windows Service testing** - Direct NSSM service installation and testing
- ✅ **Event Log integration** - Native Windows Event Viewer access
- ✅ **Production environment match** - Same OS and filesystem as deployment
- ✅ **Registry access** - Direct Windows Registry operations
- ✅ **Performance benchmarking** - Realistic large file performance testing

### **Production Readiness:**
- ✅ **Service deployment testing** - Full Windows Service lifecycle testing
- ✅ **Integration testing** - Complete Windows ecosystem integration
- ✅ **Performance validation** - Real-world SVS file processing speeds
- ✅ **Security testing** - Windows-specific security features and policies

---

## **🚨 Important Notes**

### **File Path Considerations:**
- **Windows paths**: Use `\` separators: `C:\Dev\win_repos\forker`
- **PowerShell paths**: Use forward slashes work too: `C:/Dev/win_repos/forker`
- **Git paths**: Unix-style paths still work in Git Bash

### **PowerShell Differences:**
- **Execution Policy**: Should be less restrictive on development machine
- **Module Loading**: Slightly different behavior between Windows PowerShell 5.1 and PowerShell 7
- **Cross-platform**: Code should work on both Windows and Linux

### **Performance Expectations:**
- **File I/O**: Significantly faster for large files (500MB-20GB SVS files)
- **Git operations**: Faster repository operations
- **Build times**: Improved compilation and testing speeds

### **Troubleshooting:**
- **Execution Policy Issues**: Use `Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process` for temporary fix
- **Git Authentication**: Use `gh auth refresh` if authentication expires
- **Claude Code Issues**: Restart VS Code and check extension status

---

## **🔄 Rollback Plan**

If migration encounters issues:

1. **Keep WSL environment intact** until Windows setup is fully validated
2. **Original location**: `\\wsl.localhost\Ubuntu\home\alexj\repos\forker`
3. **Backup verification**: Ensure all commits are pushed to GitHub before migration
4. **Quick rollback**: Can continue development in WSL while troubleshooting Windows setup

---

## **Next Steps After Migration**

1. **Complete Phase 5B** - Monitoring & Diagnostics implementation
2. **Windows Service Testing** - Full NSSM integration testing
3. **Performance Benchmarking** - Large SVS file processing validation
4. **Production Deployment** - Create deployment packages and documentation
5. **Integration Testing** - Complete end-to-end testing with realistic data

---

**🚀 Ready to migrate to production-realistic Windows development environment!**