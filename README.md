# A PowerShell script to sync local Git repositories with GitHub in bulk.

**Run the Script**

   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process
   cd D:\
   .\Smart-Bulk-GitHub-Push.ps1 -ParentFolder "D:\JV101"
🔁 Replace "D:\JV101" with the folder that contains all your local Git repos.
  ```

## What It Does

This script analyzes local folders and:
- ✅ Skips repos that are already connected
- 🔄 Reconnects broken remote links
- 🚀 Creates GitHub repos for local-only repos
- 👀 Optionally runs in "analyze-only" mode (no changes made)

---

## Parameters

| Name            | Description                                                            |
|-----------------|------------------------------------------------------------------------|
| `ParentFolder`  | Root folder containing all local Git repos (default: `D:\Desktop`)     |
| `Visibility`    | Visibility for new GitHub repos (`private` or `public`, default: private) |
| `DelaySeconds`  | Wait time between creating new repos (default: 90s to avoid rate limits) |
| `AnalyzeOnly`   | If set, only analyzes without changing anything                        |

---

## Categories Used:

1. **AlreadySynced**: Local repo with working GitHub remote  
2. **NeedsReconnection**: GitHub repo exists, but local remote is broken  
3. **ReadyToPush**: Local repo has commits, but no GitHub version  
4. **NeedsCommits**: Local repo exists, but has no commits yet  
5. **Problems**: Corrupted, invalid, or misconfigured repos  

---

## Script Flow

1. **Validate Folder**  
   Check if `ParentFolder` exists.

2. **Scan Subfolders**  
   Detect `.git` folders and determine the repo status.

3. **Categorize**  
   Classify each folder into one of the 5 categories above.

4. **Process (if not AnalyzeOnly)**  
   - Reconnect broken remotes  
   - Create new GitHub repos via API  
   - Push existing code to GitHub  
   - Pause between creations to avoid API rate limits

5. **Report Summary**  
   Shows counts and actions taken or suggested.

---

## 📝 Notes

- Set `$AnalyzeOnly = $false` in the script to allow real changes.
- Designed to batch-manage many repos at once.
- Useful for cleaning up inconsistent or forgotten Git setups.

