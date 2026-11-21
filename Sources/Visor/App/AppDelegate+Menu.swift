import AppKit
import ServiceManagement
import Sparkle
import VisorCore

/// The menu bar item and its menu.
extension AppDelegate {
    func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The visor from the app icon, tinted by macOS for light and dark menu bars.
        let icon = Bundle.main.image(forResource: "MenuIcon")
            ?? NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Visor")
        icon?.isTemplate = true
        icon?.accessibilityDescription = "Visor"
        item.button?.image = icon
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "About Visor", action: #selector(showAbout), keyEquivalent: "").target = self
        if let version = UpdateFeed.shared.readyVersion {
            menu.addItem(withTitle: "Restart to Update to \(version)", action: #selector(installUpdate), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Check for Updates\u{2026}", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        let automatic = menu.addItem(withTitle: "Install Updates Automatically", action: #selector(toggleAutomaticUpdates), keyEquivalent: "")
        automatic.target = self
        automatic.state = updater.updater.automaticallyDownloadsUpdates ? .on : .off
        menu.addItem(.separator())
        // Keep awake: the cup in the Agents tab sets Auto, On or Off; these two refine it.
        menu.addItem(.sectionHeader(title: "Keep Awake"))
        addToggle(to: menu, "Keep the Screen On Too", on: model.awakeScreen, #selector(toggleAwakeScreen))
        addToggle(to: menu, "Only Above 20% Battery", on: model.awakeBatteryLimit, #selector(toggleAwakeBattery))
        menu.addItem(.separator())
        let claude = HookInstaller.isInstalled
        let antigravity = HookInstaller.antigravityInstalled
        model.hooksInstalled = claude
        model.antigravityHooksInstalled = antigravity

        // Agents: a tick means connected; choosing one connects or disconnects it.
        menu.addItem(.sectionHeader(title: "Agents"))
        let claudeItem = addToggle(to: menu, "Claude Code", on: claude, #selector(toggleClaude))
        if !HookInstaller.hasClaudeCode && !claude {
            // Nothing to connect: greyed out, and says why.
            claudeItem.action = nil
            claudeItem.toolTip = "Claude Code isn't installed on this Mac"
        }
        if HookInstaller.hasCopilotCLI {
            addToggle(to: menu, "Copilot CLI", on: HookInstaller.copilotInstalled, #selector(toggleCopilot))
        }
        if HookInstaller.hasAntigravityCLI {
            addToggle(to: menu, "Antigravity CLI", on: antigravity, #selector(toggleAntigravity))
        }
        menu.addItem(.separator())

        let approvals = addToggle(to: menu, "Approvals in the Notch", on: Self.approvalsInNotch, #selector(toggleApprovals))
        approvals.toolTip = "Claude Code and Copilot CLI ask in the notch. Off, they ask in their own terminal. Antigravity always asks in its terminal."
        addToggle(to: menu, "Launch at Login", on: SMAppService.mainApp.status == .enabled, #selector(toggleLogin))
        menu.addItem(.separator())
        let extensionItem = menu.addItem(withTitle: "Browser Extension for Music\u{2026}", action: #selector(showBrowserExtension), keyEquivalent: "")
        extensionItem.target = self
        extensionItem.toolTip = "Show and control music in any browser, Firefox and Zen included"
        menu.addItem(withTitle: "Plugins Folder", action: #selector(openPluginsFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Usage", action: #selector(refreshUsage), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Quit Visor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @discardableResult
    private func addToggle(to menu: NSMenu, _ title: String, on: Bool, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleClaude() {
        if HookInstaller.isInstalled {
            try? HookInstaller.uninstall()
        } else {
            do {
                try HookInstaller.install()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't connect Claude Code"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        model.hooksInstalled = HookInstaller.isInstalled
    }

    @objc private func refreshUsage() { usage.refreshPlan() }
    @objc private func openPluginsFolder() { plugins.openFolder() }

    /// Copies the Visor Media extension where it can stay loaded, shows it in
    /// Finder and says how to add it to a browser.
    @objc private func showBrowserExtension() {
        guard let folder = BrowserBridgeServer.copyExtension() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        let alert = NSAlert()
        alert.messageText = "Add Visor Media to your browser"
        alert.informativeText = """
        With it, the notch shows and controls music and video in any browser, Firefox and Zen included, \
        and plays, pauses and skips the exact tab.

        Chrome, Dia, Arc, Brave, Edge: open the Extensions page, turn on Developer mode, choose \
        Load unpacked and pick the Extension folder now shown in Finder.

        Firefox and Zen: open about:debugging, choose This Firefox (This Zen), then Load Temporary \
        Add-on and pick manifest.json in that folder. Firefox forgets it on quit until Visor Media is on Firefox Add-ons.
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// The standard About panel, with the links from `About` under the version.
    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates(nil)
    }

    @objc private func toggleAwakeScreen() { model.awakeScreen.toggle() }
    @objc private func toggleAwakeBattery() { model.awakeBatteryLimit.toggle() }

    @objc private func toggleAutomaticUpdates() {
        updater.updater.automaticallyDownloadsUpdates.toggle()
    }

    @objc private func installUpdate() {
        UpdateFeed.shared.installNow?()
    }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString()
        for (i, link) in About.links.enumerated() {
            if i > 0 { credits.append(NSAttributedString(string: "   ")) }
            credits.append(NSAttributedString(string: link.title, attributes: [.link: link.url]))
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttributes([.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .paragraphStyle: centered],
                              range: NSRange(location: 0, length: credits.length))
        // Visor has no Dock icon and macOS may refuse to activate it, so the
        // panel is also put in front by hand or it opens behind other apps.
        NSApp.activate(ignoringOtherApps: true)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        if aboutPanel == nil { aboutPanel = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) } }
        aboutPanel?.orderFrontRegardless()
    }


    @objc private func toggleApprovals() { Self.approvalsInNotch.toggle() }

    @objc private func toggleCopilot() {
        if HookInstaller.copilotInstalled { try? HookInstaller.uninstallCopilot() } else { try? HookInstaller.installCopilot() }
    }

    @objc private func toggleAntigravity() {
        if HookInstaller.antigravityInstalled {
            try? HookInstaller.uninstallAntigravity()
        } else {
            try? HookInstaller.installAntigravity()
        }
        model.antigravityHooksInstalled = HookInstaller.antigravityInstalled
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("Visor: launch at login failed: \(error)")
        }
    }
}
