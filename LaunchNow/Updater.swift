import SwiftUI
import Foundation
import Combine

struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
}

class Updater: ObservableObject {
    static let shared = Updater()
    
    private let owner = "ggkevinnnn"
    private let repo  = "LaunchNow"
    
    @Published var showAlert = false
    @Published var alertTitle = ""
    @Published var alertMessage = ""
    @Published var alertURL: URL? = nil
    
    func checkForUpdate() {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else { return }
        
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                return
            }
            
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            
            DispatchQueue.main.async {
                if self.isVersion(release.tag_name, greaterThan: currentVersion) {
                    // 有新版本
                    self.alertTitle = NSLocalizedString("FoundNewVersion", comment: "Found New Version: ") + "\(release.tag_name)"
                    self.alertMessage = NSLocalizedString("GoToGithub", comment: "Go to Github to download the latest version")
                    self.alertURL = URL(string: release.html_url)
                } else {
                    // 已是最新版
                    self.alertTitle = NSLocalizedString("AlreadyLatest", comment: "Already the latest version: ") + "v\(currentVersion)"
                    self.alertMessage = NSLocalizedString("Enjoy", comment: "Enjoy")
                    self.alertURL = nil
                }
                self.showAlert = true
            }
        }.resume()
    }
    
    /// 从左到右比较版本号
    private func isVersion(_ versionA: String, greaterThan versionB: String) -> Bool {
        let vA = versionA.hasPrefix("v") ? String(versionA.dropFirst()) : versionA
        let vB = versionB.hasPrefix("v") ? String(versionB.dropFirst()) : versionB
        
        let componentsA = vA.split(separator: ".").compactMap { Int($0) }
        let componentsB = vB.split(separator: ".").compactMap { Int($0) }
        
        let count = max(componentsA.count, componentsB.count)
        
        for i in 0..<count {
            let a = i < componentsA.count ? componentsA[i] : 0
            let b = i < componentsB.count ? componentsB[i] : 0
            if a > b { return true }
            if a < b { return false }
        }
        return false
    }
}
