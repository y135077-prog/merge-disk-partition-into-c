# 將第二個資料碟（D:）合併回系統碟（C:）

> 在 GPT 磁碟上，把空的副分割併入 C:，同時保留／重建 Windows 修復環境（WinRE）。
> 全部使用 Windows 內建工具（PowerShell + `reagentc`），不需要 Partition Magic / DiskGenius 類第三方軟體。

實測結果：單顆 512 GB NVMe，C: 從 **237 GB → 474.8 GB**，D: 消失，WinRE 完整復原。

---

## 為什麼不能直接用 diskpart？

因為 C: 和 D: **中間夾著 1 GB 的復原分割**：

```
初始（GPT）
┌──────────┬─────┬──────────────┬──────────┬──────────────┐
│ EFI 100M │ MSR │   C: 237 GB  │ Recovery │    D: 238 GB │
│          │ 16M │              │   1 GB   │              │
└──────────┴─────┴──────────────┴──────────┴──────────────┘
                 ^^^^^^^^^^^^^^  ^^^^^^^^^^  ^^^^^^^^^^^^^^
                 C:              WinRE      ← 目標：消掉
```

`diskpart` 的 `extend` 只能吃**緊鄰**的未配置空間，不能跨過中間的分割，也無法搬移分割。
所以流程必須是：**先備份 WinRE → 停用 → 刪除後面兩塊 → 往前擴充 C: →（選用）重建復原分割**。

---

## 前置條件（動手前必讀）

| 條件 | 說明 |
|---|---|
| 系統管理員權限 | 所有步驟都需要。本機的 C 槽根目錄也只有管理員能寫 |
| D: 必須是空的 | 腳本會檢查；非空直接中止 |
| 無 BitLocker | 有 BitLocker 時修改分割需先暫停保護 |
| C: 有足夠空間 | 需能容納 WinRE 映像（本例 943 MB），建議 > 3 GB |
| 無 BitLocker 修復代理 | 復原分割若被 OEM 工具引用，刪除後該工具可能失效 |

---

## 快速開始

> ⚠️ **必須用 `powershell -ExecutionPolicy Bypass -File` 執行。**
> Windows PowerShell 預設執行原則是 `Restricted`，直接打 `.\scripts\xx.ps1`
> 會被擋下並報 `PSSecurityException`。`-ExecutionPolicy Bypass` 只影響該次呼叫，
> 不會修改系統設定（比 `Set-ExecutionPolicy Unrestricted` 安全）。

```powershell
# 1. 以系統管理員身分開啟 PowerShell
cd C:\Users\...\merge-disk-partition-into-c

# 2. 合併（備份 WinRE → 刪 D: 和復原分割 → 擴充 C:）
powershell -ExecutionPolicy Bypass -File .\scripts\01-merge-partition-into-c.ps1

# 3.（選用）重建復原分割，並把 WinRE 移回去
powershell -ExecutionPolicy Bypass -File .\scripts\02-rebuild-winre.ps1

# 4. 驗收（唯讀，不會改動任何東西）
powershell -ExecutionPolicy Bypass -File .\scripts\03-verify.ps1
```

若想在目前這個視窗直接跑（不另開子行程），先放寬當前工作階段：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\03-verify.ps1
```

`03-verify.ps1` 支援參數：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\03-verify.ps1 `
    -DiskNumber 0 -RecoveryPartitionNumber 4 -ReportPath D:\verify.txt
```

| 腳本 | 動作 | 會動到資料嗎 |
|---|---|---|
| `01-merge-partition-into-c.ps1` | 備份 WinRE → 停用 → 刪除復原分割與目標分割 → 擴充 C: | **會，不可逆** |
| `02-rebuild-winre.ps1` | 縮小 C: → 建復原分割 → 放回 wim → 重新啟用 WinRE | **會**，但失敗會自動回退到 C: |
| `03-verify.ps1` | 讀取分割表 / BCD / reagentc / DISM，產出 PASS-FAIL 報告 | 否，唯讀 |

前兩支都會把完整過程寫進日誌，並在**每個危險步驟前先驗證**；失敗時會停在安全的狀態，
不會讓系統處於「WinRE 壞掉 + 分割已刪」的中間點。

---

## 完整流程

### Step 1 — 手動備份 WinRE

> ⚠️ **坑 #1：不是每台機器都有 `reagentc /backup`**
> 部分 Windows 版本（精簡版 / Server / LTSC 分支）的 `reagentc.exe` 沒有 `/backup` 參數，
> 跑下去只會印出用法說明。判斷方式：
> ```powershell
> reagentc /backup /output C:\WinREBackup
> # 印出一堆 usage = 你的版本不支援，改用手動備份
> ```

手動備份：掛載復原分割 → 複製 `\Recovery\WindowsRE` → 取消掛載。

```powershell
Add-PartitionAccessPath -DiskNumber 0 -PartitionNumber 4 -AccessPath "R:\"
Copy-Item "R:\Recovery\WindowsRE" C:\WinREBackup -Recurse -Force
Remove-PartitionAccessPath -DiskNumber 0 -PartitionNumber 4 -AccessPath "R:\"
```

> ⚠️ **坑 #2：檔名大小寫**
> 復原分割上的檔名是全小寫 `winre.wim`。若你的磁碟區開了大小寫敏感
> （ReFS、或部分虛擬磁碟），`Test-Path "C:\WinREBackup\WinRE.wim"` 會回傳 `False`
> —— 明明檔案就在那。**驗證時務必用實際檔名大小寫**，或改用 `Get-ChildItem` 比對。

### Step 2 — 停用 WinRE

```powershell
reagentc /disable
```

停用後 `C:\Windows\System32\Recovery\ReAgent.xml` 的 `InstallState` 會變成 `0`，
`WinreLocation` 會被清空 —— 這就是「已成功停用」的判斷依據。

### Step 3 — 刪除 D: 與復原分割

```powershell
Get-Partition -DiskNumber 0 -PartitionNumber 5 | Remove-Partition   # D:
Get-Partition -DiskNumber 0 -PartitionNumber 4 | Remove-Partition   # WinRE
```

### Step 4 — 擴充 C: 到最大

```powershell
$max = (Get-PartitionSupportedSize -DiskNumber 0 -PartitionNumber 3).SizeMax
Get-Partition -DiskNumber 0 -PartitionNumber 3 | Resize-Partition -Size $max
```

### Step 5 —（選用）重建復原分割

想保留「OS 分割壞掉時還有救援環境」這層保險，就重建一塊 2 GB 的分割。
不重建的話，C: 可以拿回全部容量（多 2 GB），WinRE 改放 `C:\Recovery\WindowsRE` 一樣能運作。

---

## 坑大全

### 🔴 `New-Partition` 沒有 `-NoDefaultDriveLetter`

```powershell
New-Partition -DiskNumber 0 -Size 2GB -NoDefaultDriveLetter   # ✗ 參數不存在
New-Partition -DiskNumber 0 -Size 2GB -AssignDriveLetter:$false   # ✓
```

### 🔴 剛好差 1 MB 的「Not enough available capacity」

GPT 會在磁碟最後保留 1 MB 給次要分割表。所以「切出剛好 2 GB」會失敗：

```
可用 2049 MB，要求 2048 MB  →  New-Partition: Not enough available capacity
```

**解法：多留 32 MB 餘裕。** 腳本裡是 `$need = $recSize - $free + 32MB`。

### 🔴 復原分割別開太小 — 壓縮後 vs 展開後差 4 倍

`winre.wim` 檔案本身約 989 MB，但**展開後是 3.87 GB**（WinRE 裡面塞了完整的復原堆疊）。
2 GB 分割剛好塞得下壓縮檔，但沒有餘裕跑 `reagentc /enable` 的解壓與寫入。
建議至少給 **3 GB**，寬裕一點給 4 GB。

驗證 wim 完整性（確認不是空殼或損毀）：

```powershell
# 先暫時掛載復原分割
Add-PartitionAccessPath -DiskNumber 0 -PartitionNumber 4 -AccessPath 'R:\'
dism /Get-WimInfo /WimFile:R:\Recovery\WindowsRE\winre.wim
# 應看到：Microsoft Windows Recovery Environment (amd64) / 目錄數 / Size
```

### 🔴 `reagentc /enable` 會優先抓 `C:\Recovery\WindowsRE`

想把 WinRE 放回獨立分割，必須**先把 C: 上那份刪掉**，否則 reagentc 永遠會優先用 C: 的副本。
而 `C:\Recovery\WindowsRE` 帶有保護性 ACL，`Remove-Item` 會被拒絕，要先接手：

```powershell
takeown /f "C:\Recovery\WindowsRE" /r /d y
icacls "C:\Recovery\WindowsRE" /grant *S-1-5-32-544:(OI)(CI)F /t /q
rd /s /q "C:\Recovery\WindowsRE"
```

### 🔴 `reagentc` 的輸出會消失或是亂碼

把 `reagentc` 的輸出接進 PowerShell 管線有時會拿到空字串（尤其在提升權限的子行程）。
可靠的做法是**重導向到檔案再讀**：

```powershell
cmd /c "reagentc /info > %TEMP%\re.txt 2>&1"
Get-Content "$env:TEMP\re.txt" -Raw
```

### 🟡 縮減分割時別拿 `SizeMax` 當基準

`Get-PartitionSupportedSize` 回傳的 `SizeMax` 是「這顆磁碟能擴到的最大」，
**不是「目前的容量」**。要縮小得用目前大小去減：

```powershell
$cur = (Get-Partition -DiskNumber 0 -PartitionNumber 3).Size
Resize-Partition -Size ($cur - 2GB)      # ✓  縮小
Resize-Partition -Size ($sup.SizeMax - 2GB)   # ✗  反而會長大
```

### 🟡 `Get-Item` 對某些檔案會回報不存在

在受過濾驅動（防毒、雲端同步）或多層掛載的環境下，`Test-Path` 說有、
`Get-ChildItem` 也列得出來，但 `Get-Item` 卻說找不到。取得檔案大小用：

```powershell
(Get-ChildItem $dir -Filter 'winre.wim' -Force | Select-Object -First 1).Length
```

### 🟡 腳本檔的編碼

Windows PowerShell 5.1 讀 `.ps1` 檔用的是**系統 ANSI 碼頁**（繁中機是 Big5/950），
用 UTF-8（無 BOM）存的中文註解會被解讀成亂碼，導致**整支腳本語法錯誤、什麼都不做**。
兩種解法：存成 UTF-8 with BOM，或腳本內全用 ASCII。
本 repo 的腳本全部維持 **ASCII only**（中文說明放在 README）。

### 🟡 直接打 `.\xx.ps1` 會被執行原則擋下

```
.\scripts\03-verify.ps1 : 因為這個系統上已停用指令碼執行，所以無法載入 ... 檔案
    + FullyQualifiedErrorId : UnauthorizedAccess
```

Windows PowerShell 的預設執行原則是 `Restricted`，任何下載或複製來的 `.ps1`
都會被拒絕執行。**不要**為了省事去 `Set-ExecutionPolicy Unrestricted`（全域放寬），
改用單次呼叫：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\03-verify.ps1
```

或只放寬目前這個工作階段（關掉視窗就失效）：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

若要永久信任這個路徑，用 `Unblock-File` 解除檔案上的「從網路下載」封鎖標記：

```powershell
Get-ChildItem .\scripts\*.ps1 | Unblock-File
```

### 🔴 `Write-Host 'a' + $var` 會**靜默吞掉** `$var`

這題目在 PowerShell 裡超級常見，而且不會丟錯，只會少印東西：

```powershell
function W($m) { Write-Host $m }
$n = 5

W '  RESULT: ' + $n + ' CHECKS FAILED'   # 輸出只有：  RESULT:
W ('  RESULT: ' + $n + ' CHECKS FAILED')  # 輸出：      RESULT: 5 CHECKS FAILED  ✓
```

原因：命令引數的解析模式遇到運算子就停。`W '  RESULT: ' + $n + ' ...'`
會被拆成「呼叫 `W`，引數是 `'  RESULT: '`」，後面的 `+ $n + ' ...'`
變成另一段獨立敘述被丟棄。**只要有變數相加，務必加括號或改用 `-f`：**

```powershell
W ('  RESULT: ' + $n + ' CHECKS FAILED')
W ('  {0,-44} {1}' -f $f, $present)      # -f 最安全
```

### 🔴 驗證腳本不要把「沒檢查到」當成「通過」

第一版的 `03-verify.ps1` 有三個假通過，都是同一個病根 —— 預設值刚好等於通過條件：

```powershell
# 掛載失敗時 action 根本沒執行，$efiOk 停在初始值 $true
$efiOk = $true
With-MountedPartition ... { $efiOk = $false }   # 掛不上就不會跑
Assert-True $efiOk                              # → 假 PASS

# bcdedit 失敗時兩個變數都是 $null，$null -eq $null 為 true
Assert-True ($currentId -eq $winreObj)           # → 假 PASS
```

所以腳本改成**三態**（PASS / FAIL / SKIP），且：

- 每個跳過的項目都記在 `skipped` 計數裡，結束代碼 `2` 表示「報告不完整」
- 比較兩個變數前先確認兩者都非 null
- 讀不掉的檔案用 `try/catch` 分成 yes / no / denied 三種，不用 `Test-Path` 的
  布爾結果（權限不足時 `Test-Path` 會丟出非終止錯誤，指令還會**繼續往下跑**並印出
  「does not exist (good)」這種完全相反的結論）

---

## 驗收清單

最快的做法是跑驗證腳本（**唯讀**，會產出 `verify-report.txt` 並列出每項檢查的狀態）：

```powershell
# 必須在「系統管理員」PowerShell 執行
powershell -ExecutionPolicy Bypass -File .\scripts\03-verify.ps1
```

它會檢查：分割表（EFI / MSR / C: / 復原分割的 GPT type）、D: 是否消失、
`reagentc /info`、BCD 的 `recoveryenabled` 與 `recoverysequence`、WinRE 物件的
`ramdisk` 是否解析到真實磁碟區、有沒有孤兒 `[unknown]` BCD 物件、EFI 開機檔是否存在、
wim 映像完整性（並比對**展開後**大小 vs 復原分割容量）、
以及是否還有殘留的 `C:\Recovery\WindowsRE` 或指向 `D:` 的登錄檔／環境變數。

**每項檢查是三態的**，這點很重要 —— 檢查「做不成」不等於「檢查失敗」：

| 狀態 | 意義 | 計入 |
|---|---|---|
| `PASS` | 條件成立 | pass |
| `FAIL` | 條件不成立 | **fail** |
| `SKIP` | 無法評估（沒權限、工具不存在、路徑被擋） | 報告為略過，**不算 pass** |

結束代碼：`0` = 全過、`1` = 有失敗、`2` = 沒失敗但有略過。
拿 `2` 當成功是錯的 —— 它代表報告不完整。

腳本預設**拒絕在非管理員 shell 執行**（因為 `reagentc` / `bcdedit` / DISM /
`Add-PartitionAccessPath` 全部需要系統管理員權限，硬跑只會產生一整頁假的失敗）。
只想先看分割表可以加：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\03-verify.ps1 -AllowNotElevated
```

要手動查的話：

```powershell
reagentc /info        # Windows RE status: Enabled
Get-Partition -DiskNumber 0 | Format-Table PartitionNumber, DriveLetter, Size, GptType
Get-Volume | Format-Table DriveLetter, Size, SizeRemaining
bcdedit /enum all | findstr /i unknown recoveryenabled recoverysequence
```

通過標準：

- [ ] `Get-Volume` 裡 **D: 不存在**
- [ ] C: 容量 ≈ 磁碟總容量 − 復原分割大小
- [ ] `reagentc /info` → `Windows RE status: Enabled`，且位置指向復原分割
      （`\\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE`）
- [ ] 復原分割上有 `\Recovery\WindowsRE\winre.wim`，且 `dism /Get-WimInfo` 讀得出來
- [ ] `bcdedit /enum all` 中 `{current}` 的 `recoveryenabled = Yes`
- [ ] `bcdedit /enum all` 中**沒有任何 `[unknown]` 殘留**（舊分割的孤兒項）
- [ ] WinRE 的 BCD 物件 `ramdisk=` 指向真實磁碟區而非 `[unknown]`：

```
identifier              {71d9d4d1-bba3-11f1-9b01-18473d2be80c}
device                  ramdisk=[\Device\HarddiskVolume6]\Recovery\WindowsRE\Winre.wim,{71d9d4d2-...}
osdevice                ramdisk=[\Device\HarddiskVolume6]\Recovery\WindowsRE\Winre.wim,{71d9d4d2-...}
winpe                   Yes
```

> `[\Device\HarddiskVolume6]` 這個編號不重要，**重要的是它不是 `[unknown]`** ——
> 代表開機管理程式真的解析到了 WinRE 所在的磁碟區。

### 重開機後的實機驗證

非侵入性檢查通過後，**一定要實際重開機一次**：

| 測試 | 做法 | 通過標準 |
|---|---|---|
| 正常開機 | 直接重開機 | 進到登入畫面、帳號可登入、檔案總管看到 474.8 GB |
| 進修復選單 | `Win + Shift + 重新開機` → 使用裝置 → 疑難排解 | 藍底 WinRE 選單出來 |
| 進階選項 | 疑難排解 → 進階選項 | 看到啟動修復 / 系統還原 / 安全模式 / 命令提示字元 / UEFI 韌體設定 |
| **唯讀驗證（建議做）** | 在 WinRE 開「命令提示字元」跑 `diskpart` → `list disk` → `list partition` | 看到 4 個分割（100M / 16M / 474.8G / 2.0G） |
| 重設此電腦 | 回到 Windows，設定 → 系統 → 復原 | 「重設此電腦」可選（**不要真的按下去**） |
| 自動修復（選用） | 開機中連續 3 次長按電源鍵強制關機，第 4 次開機 | 出現「自動修復」並載入 WinRE |

最後一項會真的讓 Windows 判定開機失敗，需要跑一次「啟動修復」或進安全模式才能回來。
前五項都通過就可以跳過。

實測輸出範例：

```
Windows RE status: Enabled
Windows RE location: \\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE
Windows RE Version: 10.0.26100.9444

Part1  (no letter)  System    0.098 GB
Part2  (no letter)  Reserved  0.016 GB
Part3  C:           Basic   474.795 GB
Part4  (no letter)  Recovery    2.000 GB
```

---

## 注意事項與風險

- **此操作不可逆。** 分割一旦刪除，資料救不回來。動手前務必確認 D: 真的沒東西。
- **保留一份 `winre.wim` 備份** 在 `C:\WinREBackup\` 直到確認新配置能開機進復原選單為止。
- **OEM 廠商工具** 若依賴出廠那塊復原分割（Lenovo Vantage、Dell Recovery 等），刪除後該功能會失效。
- **舊的 BCD 項目** 會變成指向已刪除分割的 `[unknown]` 殘留項。只要沒被 `displayorder`、
  `toolsdisplayorder`、`recoverysequence`、`default`、`resumeobject` 引用，它就不會出現在
  開機選單，可安全忽略。要清掉的話注意指令是 **`bcdedit /delete {<GUID>}`**
  （不是 `/deletebase`，那個子命令不存在）：
  ```powershell
  bcdedit /export C:\BCD-backup.bcd      # 先備份
  bcdedit /delete {<GUID>}
  bcdedit /enum all | findstr unknown    # 應無輸出
  ```
- **本流程會縮減再擴充 C:**（重建復原分割時）。NTFS 可線上縮小，但若檔案碎片在磁碟尾端，
  縮小可能失敗 —— 先跑一次「磁碟碎片整理工具」再試。
- 合併後請**重新開機**一次確認開機選單與「重設此電腦」都正常。

## 復原方式

如果新配置有問題：

```powershell
# 把 WinRE 裝回 C:
New-Item -ItemType Directory -Path C:\Recovery\WindowsRE -Force
Copy-Item C:\WinREBackup\winre.wim C:\Recovery\WindowsRE\winre.wim -Force
reagentc /enable
reagentc /info      # 應顯示 Enabled
```

---

## License

MIT — 詳見 [LICENSE](LICENSE)。
