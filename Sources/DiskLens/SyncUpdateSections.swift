import SwiftUI

/// The iCloud settings sync and update choices, as two sections for a grouped Settings form.
struct SyncUpdateSections: View {
    @ObservedObject private var sync = SettingsSync.shared
    @ObservedObject private var updater = AutoUpdater.shared

    var body: some View {
        Section {
            Toggle("Sync settings with your other Macs", isOn: $sync.isEnabled)
            if sync.isEnabled {
                LabeledContent {
                    Button("Sync Now") { sync.syncNow() }
                } label: {
                    if let error = sync.lastError {
                        Text(error).foregroundStyle(.red)
                    } else if let date = sync.lastSynced {
                        Text("Synced \(date.formatted(date: .omitted, time: .shortened))\(sync.lastSource.map { $0 == (Host.current().localizedName ?? "") ? "" : " from \($0)" } ?? "")")
                    } else {
                        Text("Waiting for iCloud Drive…")
                    }
                }
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Where DiskLens appears, its colors, chart style and cleanup threshold follow you to every Mac signed in to the same iCloud account with sync turned on. The folders you scan and your saved scans stay on each Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Picker("When an update is available", selection: $updater.policy) {
                ForEach(UpdatePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if updater.policy != .off {
                UpdateIntervalPicker(interval: $updater.interval)
            }
            if let staged = updater.staged {
                LabeledContent("Version \(staged.version) is ready") {
                    Button("Install Now") { updater.installNow() }
                }
            }
            LabeledContent("Version \(AppInfo.displayVersion)") {
                Button("Check Now") { UpdateController.checkForUpdates() }
            }
            if let error = updater.lastError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if updater.policy != .off && !updater.notificationsAllowed {
                LabeledContent {
                    Button("Open Notification Settings") { AutoUpdater.openNotificationSettings() }
                } label: {
                    Label("Notifications are off for DiskLens, so update news only shows in the menu.", systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(updateFooter).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { updater.refreshNotificationStatus() }
    }

    private var updateFooter: String {
        switch updater.policy {
        case .automatic:
            return "DiskLens checks \(updater.interval.phrase). A new version installs itself when no scan is running, nothing is waiting in the Trash list, no app is presenting or keeping the screen awake, and your Mac hasn't been used for 2 minutes. You'll get a notification when it's done."
        case .ask:
            return "DiskLens checks \(updater.interval.phrase) and sends a notification when a new version is out. Nothing installs until you choose to."
        case .off:
            return "DiskLens won't look for updates on its own. Use Check Now whenever you like."
        }
    }
}
