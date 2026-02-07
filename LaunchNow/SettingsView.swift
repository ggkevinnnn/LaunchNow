import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftData

struct SettingsView: View {
    @ObservedObject var appStore: AppStore
    @StateObject private var updater = Updater.shared
    @State private var showResetConfirm = false
    @State private var hideAppSearchText: String = ""
    @State private var showAddHiddenApps: Bool = false
    @State private var pendingHiddenSelections: Set<String> = []

    var body: some View {
        let hidableApps = appStore.hidableApps(searchText: hideAppSearchText)
        let hiddenApps = hidableApps.filter { appStore.isAppHidden(path: $0.url.path) }
        let addableApps = hidableApps.filter { !appStore.isAppHidden(path: $0.url.path) }
        VStack {
            HStack(alignment: .firstTextBaseline) {
                Text("LaunchNow")
                    .font(.title)
                Text("v\(getVersion())")
                    .font(.footnote)
                Spacer()
                Button {
                    appStore.isSetting = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2.bold())
                        .foregroundStyle(.placeholder)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            
            VStack {
                HStack {
                    Text(NSLocalizedString("Style", comment: "Classic Launchpad (Fullscreen)"))
                    Spacer()
                    Toggle(isOn: $appStore.isFullscreenMode) {
                        
                    }
                    .toggleStyle(.switch)
                }
                HStack {
                    Text(NSLocalizedString("ShowAppName", comment: "Show app name"))
                    Spacer()
                    Toggle(isOn: $appStore.showAppNameBelowIcon) {}
                        .toggleStyle(.switch)
                }
                HStack {
                    Text(NSLocalizedString("ScrollSensitivity", comment: "Scrolling sensitivity"))
                    VStack {
                        Slider(value: $appStore.scrollSensitivity, in: 0.01...0.99)
                        HStack {
                            Text(NSLocalizedString("Low", comment: "Low"))
                                .font(.footnote)
                            Spacer()
                            Text(NSLocalizedString("High", comment: "High"))
                                .font(.footnote)
                        }
                    }
                }
                HStack {
                    Text(NSLocalizedString("IconSize", comment: "Icon size"))
                    VStack {
                        Slider(value: $appStore.iconScale, in: 0.3...1.2)
                        HStack {
                            Text(NSLocalizedString("Small", comment: "Small"))
                                .font(.footnote)
                            Spacer()
                            Text(NSLocalizedString("Large", comment: "Large"))
                                .font(.footnote)
                        }
                    }
                    Button {
                        appStore.iconScale = 0.8
                    } label: {
                        Text(NSLocalizedString("DefaultSize", comment: "Default size"))
                    }
                }
                HStack {
                    Text(NSLocalizedString("DisplayedLanguage", comment: "Displayed Language"))
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization")!)
                        AppDelegate.shared?.hideWindow()
                    } label: {
                        Text(NSLocalizedString("Language", comment: "Language..."))
                    }
                }
            }
            .padding()
            
            Divider()
            
            VStack(alignment: .leading) {
                HStack {
                    Text(NSLocalizedString("CustomizeScannedFolder", comment: "Customize scanned folder"))
                    Spacer()
                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = true
                        panel.canCreateDirectories = false
                        panel.prompt = NSLocalizedString("Add", comment: "Add")
                        panel.message = NSLocalizedString("AddFolder", comment: "Add folder")
                        if panel.runModal() == .OK {
                            let chosen = panel.urls.map { $0.path }
                            var merged = appStore.customSearchPaths
                            for p in chosen {
                                let expanded = (p as NSString).expandingTildeInPath
                                if !merged.contains(expanded) {
                                    merged.append(expanded)
                                }
                            }
                            appStore.customSearchPaths = merged
                        }
                    } label: {
                        Label(NSLocalizedString("Add", comment: "Add"), systemImage: "plus")
                    }
                    Button {
                        appStore.resetDefaultSearchPaths()
                    } label: {
                        Label(NSLocalizedString("ResetToDefault", comment: "Reset to default"), systemImage: "arrow.uturn.backward")
                    }
                }
                .padding(.bottom)
                
                // 列表 + 添加按钮
                VStack(alignment: .leading) {
                    if appStore.defaultSearchPaths.isEmpty && appStore.customSearchPaths.isEmpty {
                        Text(NSLocalizedString("NoFolders", comment: "No folders"))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    } else {
                        ScrollView {
                            ForEach(Array(appStore.defaultSearchPaths.enumerated()), id: \.offset) { idx, path in
                                HStack {
                                    Text(path)
                                        .font(.footnote)
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .padding(.vertical, 3)
                                    Spacer()
                                    Button(role: .destructive) {
                                        var paths = appStore.defaultSearchPaths
                                        if idx < paths.count { paths.remove(at: idx) }
                                        appStore.defaultSearchPaths = paths
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.footnote)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            ForEach(Array(appStore.customSearchPaths.enumerated()), id: \.offset) { idx, path in
                                HStack {
                                    Text(path)
                                        .font(.footnote)
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .padding(.vertical, 3)
                                    Spacer()
                                    Button(role: .destructive) {
                                        var paths = appStore.customSearchPaths
                                        if idx < paths.count { paths.remove(at: idx) }
                                        appStore.customSearchPaths = paths
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.footnote)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(height: 100)
                        .scrollIndicators(.hidden)
                    }
                }
            }
            .padding()
            
            Divider()
            
            VStack(alignment: .leading) {
                HStack {
                    Text(NSLocalizedString("HiddenApps", comment: "Hide apps from grid"))
                    Spacer()
                    Button {
                        showAddHiddenApps = true
                    } label: {
                        Label(NSLocalizedString("Add", comment: "Add"), systemImage: "plus")
                    }
                    Button {
                        let hiddenApps = appStore.hidableApps(searchText: "")
                            .filter { appStore.isAppHidden(path: $0.url.path) }
                        for app in hiddenApps {
                            appStore.setAppHidden(false, app: app)
                        }
                    } label: {
                        Label(NSLocalizedString("ClearHiddenApps", comment: "Clear hidden apps"), systemImage: "arrow.uturn.backward")
                    }
                }

                if hiddenApps.isEmpty {
                    Text(NSLocalizedString("NoHiddenApps", comment: "No hidden apps"))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(hiddenApps, id: \.id) { app in
                                HStack(spacing: 10) {
                                    Image(nsImage: app.icon)
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name)
                                            .font(.body)
                                        Text(app.url.path)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        appStore.setAppHidden(false, app: app)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.footnote)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 100)
                }

            }
            .padding()
            .sheet(isPresented: $showAddHiddenApps) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(NSLocalizedString("AddHiddenApps", comment: "Add hidden apps"))
                            .font(.title)
                        Spacer()
                        .buttonStyle(.plain)
                        Button {
                            showAddHiddenApps = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.title3.bold())
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    TextField(NSLocalizedString("Search", comment: "Search"), text: $hideAppSearchText)
                        .textFieldStyle(.roundedBorder)

                    if addableApps.isEmpty {
                        Text(NSLocalizedString("NoAppsFound", comment: "No apps found"))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(addableApps, id: \.id) { app in
                                    HStack(spacing: 10) {
                                        Image(nsImage: app.icon)
                                            .resizable()
                                            .frame(width: 20, height: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(app.name)
                                                .font(.body)
                                            Text(app.url.path)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        
                                        Spacer()
                                        
                                        Toggle("", isOn: Binding(
                                            get: { pendingHiddenSelections.contains(app.url.path) },
                                            set: { isOn in
                                                if isOn {
                                                    pendingHiddenSelections.insert(app.url.path)
                                                } else {
                                                    pendingHiddenSelections.remove(app.url.path)
                                                }
                                            }
                                        ))
                                        .labelsHidden()
                                        .toggleStyle(.checkbox)
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal)
                        }
                        .frame(height: 500)
                        .padding()
                    }
                    
                    HStack {
                        Spacer()
                        Button(NSLocalizedString("Confirm", comment: "Confirm")) {
                            for path in pendingHiddenSelections {
                                if let app = addableApps.first(where: { $0.url.path == path }) {
                                    appStore.setAppHidden(true, app: app)
                                }
                            }
                            pendingHiddenSelections.removeAll()
                            showAddHiddenApps = false
                        }
                        .disabled(pendingHiddenSelections.isEmpty)
                    }
                }
                .padding()
                .padding()
                .onAppear {
                    pendingHiddenSelections.removeAll()
                }
            }
            
            Divider()
            
            HStack {
                Button {
                    exportDataFolder()
                } label: {
                    Label(NSLocalizedString("Export", comment: "Export Data"), systemImage: "square.and.arrow.up")
                }

                Button {
                    importDataFolder()
                } label: {
                    Label(NSLocalizedString("Import", comment: "Import Data"), systemImage: "square.and.arrow.down")
                }
            }
            .padding()
            
            Divider()
            
            HStack {
                Button(NSLocalizedString("CheckUpdates", comment: "Check for Updates")) {
                    Updater.shared.checkForUpdate()
                }
                .alert(updater.alertTitle, isPresented: $updater.showAlert) {
                    if let url = updater.alertURL {
                        Button(NSLocalizedString("Confirm", comment: "Confirm")) {
                            NSWorkspace.shared.open(url)
                            AppDelegate.shared?.hideWindow()
                        }
                        Button(NSLocalizedString("Cancel", comment: "Cancel"), role: .cancel) {}
                    } else {
                        Button(NSLocalizedString("Confirm", comment: "Confirm"), role: .cancel) {}
                    }
                } message: {
                    Text(updater.alertMessage)
                }
                
                Spacer()
                
                Button {
                    appStore.showWelcomeSheet = true
                } label: {
                    Text(NSLocalizedString("ShowWelcome", comment: "Show Introduction"))
                }
                .sheet(isPresented: $appStore.showWelcomeSheet) {
                    WelcomeView(appStore: appStore)
                }
            }
            .padding(.horizontal)
            .padding(.top)

            HStack {
                Button {
                    appStore.refresh()
                } label: {
                    Label(NSLocalizedString("Refresh", comment: "Refresh"), systemImage: "arrow.clockwise")
                }

                Spacer()

                Button {
                    showResetConfirm = true
                } label: {
                    Label(NSLocalizedString("ResetLayout", comment: "Reset Layout"), systemImage: "arrow.counterclockwise")
                        .foregroundStyle(Color.red)
                }
                .alert(NSLocalizedString("ConfirmReset", comment: "Confirm to reset layout?"), isPresented: $showResetConfirm) {
                    Button(NSLocalizedString("Reset", comment: "Reset"), role: .destructive) { appStore.resetLayout() }
                    Button(NSLocalizedString("Cancel", comment: "Cancel"), role: .cancel) {}
                } message: {
                    Text(NSLocalizedString("ResetAlert", comment: "ResetAlert"))
                }
                                
                Button {
                    exit(0)
                } label: {
                    Label(NSLocalizedString("Quit", comment: "Quit"), systemImage: "xmark.circle")
                        .foregroundStyle(Color.red)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)

        }
        .padding()
    }
    
    func getVersion() -> String {
            return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    // MARK: - Export / Import Application Support Data
    private func supportDirectoryURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("LaunchNow", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func exportDataFolder() {
        do {
            let sourceDir = try supportDirectoryURL()
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            panel.message = "Choose a destination folder to export LaunchNow data"
            if panel.runModal() == .OK, let destParent = panel.url {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let folderName = "LaunchNow_Export_" + formatter.string(from: Date())
                let destDir = destParent.appendingPathComponent(folderName, isDirectory: true)
                try copyDirectory(from: sourceDir, to: destDir)
            }
        } catch {
            // 忽略错误或可在此添加用户提示
        }
    }

    private func importDataFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a folder previously exported from LaunchNow"
        if panel.runModal() == .OK, let srcDir = panel.url {
            do {
                // 验证是否为有效的排序数据目录
                guard isValidExportFolder(srcDir) else { return }
                let destDir = try supportDirectoryURL()
                // 若用户选的就是目标目录，跳过
                if srcDir.standardizedFileURL == destDir.standardizedFileURL { return }
                try replaceDirectory(with: srcDir, at: destDir)
                // 导入完成后加载并刷新
                appStore.applyOrderAndFolders()
                appStore.refresh()
            } catch {
                // 忽略错误或可在此添加用户提示
            }
        }
    }

    private func copyDirectory(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }

    private func replaceDirectory(with src: URL, at dst: URL) throws {
        let fm = FileManager.default
        // 确保父目录存在
        let parent = dst.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }

    private func isValidExportFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        let storeURL = folder.appendingPathComponent("Data.store")
        guard fm.fileExists(atPath: storeURL.path) else { return false }
        // 尝试打开该库并检查是否有排序数据
        do {
            let config = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(for: TopItemData.self, PageEntryData.self, configurations: config)
            let ctx = container.mainContext
            let pageEntries = try ctx.fetch(FetchDescriptor<PageEntryData>())
            if !pageEntries.isEmpty { return true }
            let legacyEntries = try ctx.fetch(FetchDescriptor<TopItemData>())
            return !legacyEntries.isEmpty
        } catch {
            return false
        }
    }
}
