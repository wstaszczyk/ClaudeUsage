# ClaudeUsage — Step-by-step Xcode setup

No prior Xcode experience needed. Follow every step in order.

---

## Step 1 — Install Xcode

Open the **App Store**, search for **Xcode**, and install it.
It's large (~10 GB). After it installs, open it once so it finishes setting up its tools — it will ask for your password and spend a minute installing components. Once you see the welcome screen, you're ready.

---

## Step 2 — Create a new project

1. Open **Xcode**
2. On the welcome screen, click **Create New Project…**
   *(or from the menu bar: File → New → Project)*
3. At the top of the template chooser, make sure **macOS** is selected
4. Choose **App** → click **Next**

---

## Step 3 — Configure the project

Fill in the form exactly like this:

| Field | Value |
|---|---|
| Product Name | `ClaudeUsage` |
| Team | None *(leave empty or pick your personal team if you have one)* |
| Organization Identifier | `com.local` |
| Bundle Identifier | will auto-fill as `com.local.ClaudeUsage` |
| Interface | **SwiftUI** |
| Language | **Swift** |

Click **Next**.

---

## Step 4 — Save the project

A file picker appears asking where to save.

1. Navigate to your **Documents → Claude Code → ai-makers-club** folder
2. You should see a folder named **ClaudeUsage** already there
3. **Select that folder** as the save location
4. Uncheck *"Create Git repository"* (we'll manage that ourselves)
5. Click **Create**

Xcode opens with a default project. You'll see files in the left sidebar (the **Project Navigator**).

---

## Step 5 — Delete the default ContentView file

In the left sidebar, find **ContentView.swift** — it was created automatically but we don't need it.

1. Right-click **ContentView.swift**
2. Choose **Delete**
3. In the dialog that appears, click **Move to Trash**

---

## Step 6 — Replace the main App file

Xcode created a file called **ClaudeUsageApp.swift** with some default code. We need to replace its contents.

1. Click **ClaudeUsageApp.swift** in the sidebar to open it
2. Press **⌘A** to select all its contents
3. Delete it (press Backspace)
4. Open Finder and navigate to:
   `Documents → Claude Code → ai-makers-club → ClaudeUsage → ClaudeUsage`
5. Open **ClaudeUsageApp.swift** in TextEdit (right-click → Open With → TextEdit)
6. Press **⌘A** then **⌘C** to copy all its contents
7. Switch back to Xcode and press **⌘V** to paste

---

## Step 7 — Add the remaining source files

Now we need to bring in the other three Swift files.

1. In the Project Navigator sidebar, **right-click** on the **ClaudeUsage folder** (the yellow folder icon, not the blue project icon at the top)
2. Choose **Add Files to "ClaudeUsage"…**
3. Navigate to: `Documents → Claude Code → ai-makers-club → ClaudeUsage → ClaudeUsage`
4. Hold **⌘** and click to select all three files:
   - `UsageService.swift`
   - `UsageViewModel.swift`
   - `MenuBarView.swift`
5. Make sure **"Copy items if needed"** is checked and **"Add to targets: ClaudeUsage"** is checked
6. Click **Add**

You should now see all four `.swift` files in the sidebar.

---

## Step 8 — Hide the Dock icon

By default macOS apps show an icon in the Dock. For a menu bar app, we want to hide it.

1. In the sidebar, click the **blue project icon** at the very top (it says "ClaudeUsage" with a number next to it)
2. In the main panel, click **ClaudeUsage** under **TARGETS** (not under PROJECTS)
3. Click the **Info** tab at the top of the panel
4. Scroll to the bottom of the list of keys
5. Hover over any row — a **+** button appears on the left
6. Click the **+** button to add a new row
7. Type `Application is agent` and press Enter — Xcode will auto-complete to **Application is agent (UIElement)**
8. The value column will show a checkbox — make sure it is **checked** (YES)

---

## Step 9 — Link the SQLite library

The app reads Claude's cookie database (a SQLite file). We need to tell the compiler to include the SQLite library.

1. Still in the target settings, click the **Build Settings** tab
2. In the search box at the top, type `Other Linker Flags`
3. You'll see a row called **Other Linker Flags** — double-click its value column
4. A small editor appears — click the **+** button inside it
5. Type `-lsqlite3` and press Enter
6. Click somewhere else to close the editor

---

## Step 10 — Set the minimum macOS version

1. Still in Build Settings, search for `MACOSX_DEPLOYMENT_TARGET`
2. Double-click the value and type `13.0`
3. Press Enter

---

## Step 11 — Build and run

Press **⌘R** (or click the ▶ play button in the top-left toolbar).

Xcode will compile the app (~10–20 seconds). When it's done:

- A macOS **Keychain dialog** appears asking:
  > *"ClaudeUsage" wants to access "Claude Safe Storage" in your keychain*
  
  Click **Always Allow** — this is a one-time step. The app reads (never writes) Claude Desktop's session key.

- Look at the **top-right of your menu bar** — you should see something like `35% · 22:50` appear within a few seconds.

- Click it to see the full popover with progress bars and weekly usage.

---

## Troubleshooting

**Build fails with "module 'CommonCrypto' not found"**
→ Make sure the deployment target is macOS 13.0 (Step 10).

**App shows ⚠ instead of a percentage**
→ Make sure Claude Desktop is running. The app reads its session data.

**Keychain dialog keeps appearing**
→ You clicked "Allow" instead of "Always Allow". Delete the app from Keychain Access and re-run, then click "Always Allow".

**App still shows in the Dock**
→ Double-check Step 8 — the checkbox must be ticked (YES).

---

## Making it launch automatically at login

Once the app is working:

1. Open **System Settings → General → Login Items**
2. Click the **+** under "Open at Login"
3. Navigate to `~/Library/Developer/Xcode/DerivedData/ClaudeUsage-.../Build/Products/Debug/` and add `ClaudeUsage.app`

Or: Product → Archive in Xcode to build a release version, move it to `/Applications`, then add it from there.
