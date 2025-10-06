import Foundation

public func localizedAppName(for bundleURL: URL) -> String {
    guard let bundle = Bundle(url: bundleURL) else {
        return bundleURL.deletingPathExtension().lastPathComponent
    }

    // 0) Apply special-case overrides first
    if let special = specialCaseNameIfAny(for: bundle) {
        return special
    }

    let languagesToTry = preferredLanguageOrder(for: bundle)

    // 1) Read InfoPlist.strings in the best matching .lproj folder
    for lang in languagesToTry {
        if let strings = readInfoPlistStrings(in: bundle, for: lang) {
            if let name = strings["CFBundleDisplayName"] ?? strings["CFBundleName"], !name.isEmpty {
                return name
            }
        }
    }

    // 2) Use Bundle.localizedInfoDictionary from the target bundle
    if let localizedDict = bundle.localizedInfoDictionary {
        if let name = localizedDict["CFBundleDisplayName"] as? String ?? localizedDict["CFBundleName"] as? String,
           !name.isEmpty {
            return name
        }
    }

    // 3) Use Bundle.infoDictionary values
    if let infoDict = bundle.infoDictionary {
        if let name = infoDict["CFBundleDisplayName"] as? String ?? infoDict["CFBundleName"] as? String,
           !name.isEmpty {
            return name
        }
    }

    // 3.5) Use URLResourceValues.localizedName
    if let values = try? bundleURL.resourceValues(forKeys: [.localizedNameKey]),
       let localized = values.localizedName, !localized.isEmpty {
        return localized
    }

    // 4) Use FileManager's displayName(atPath:) and apply special-case mapping for well-known Apple apps
    let path = bundleURL.path
    let fsName = FileManager.default.displayName(atPath: path)
    if !fsName.isEmpty {
        // Apply special-case overrides when needed
        return specialCaseLocalizedName(for: bundle, fallback: fsName)
    }

    // 4.5) Apply special-case mapping before the ultimate fallback
    let finalFallback = specialCaseLocalizedName(for: bundle, fallback: bundleURL.deletingPathExtension().lastPathComponent)
    return finalFallback
}

private func preferredLanguageOrder(for bundle: Bundle) -> [String] {
    // Normalize language ID (e.g. zh-Hans, zh-Hant) and primary codes
    func normalizedLanguageIDs(_ ids: [String]) -> [String] {
        ids.compactMap { id in
            let normalized = Locale(identifier: id).language.languageCode?.identifier ?? id
            return normalized
        }
    }

    var result = [String]()
    let preferred = Locale.preferredLanguages
    let available = bundle.localizations.map { $0.lowercased() }
    let devLoc = bundle.developmentLocalization?.lowercased()

    // Set to preserve order and uniqueness
    var seen = Set<String>()

    func addIfValid(_ lang: String) {
        let lower = lang.lowercased()
        if !lower.isEmpty && !seen.contains(lower) {
            seen.insert(lower)
            result.append(lower)
        }
    }

    // 1) Try preferredLanguages intersected with available localizations (exact or primary)
    for pref in preferred {
        let prefLower = pref.lowercased()
        if available.contains(prefLower) {
            addIfValid(prefLower)
        } else {
            // try primary language only
            if let primary = Locale(identifier: pref).language.languageCode?.identifier.lowercased(),
               available.contains(primary) {
                addIfValid(primary)
            }
        }
    }

    // 2) Add developmentLocalization if not already added
    if let dev = devLoc, !dev.isEmpty {
        if !seen.contains(dev) {
            if available.contains(dev) {
                addIfValid(dev)
            } else if let primary = Locale(identifier: dev).language.languageCode?.identifier.lowercased(),
                      available.contains(primary) {
                addIfValid(primary)
            }
        }
    }

    // 3) Add "en" fallback if not present
    if !seen.contains("en") && available.contains("en") {
        addIfValid("en")
    }

    return result
}

private func readInfoPlistStrings(in bundle: Bundle, for languageCode: String) -> [String: String]? {
    // Attempt to find the best .lproj folder for the given languageCode
    // Normalize language code to match folder names (e.g. zh-Hans.lproj, en.lproj)
    // We try exact match or primary code variant

    let lprojDirs = bundle.paths(forResourcesOfType: "lproj", inDirectory: nil).map { URL(fileURLWithPath: $0) }

    // Normalize requested language code and primary code
    let requestedLang = languageCode.lowercased()
    let requestedPrimary = Locale(identifier: requestedLang).language.languageCode?.identifier.lowercased()

    func matchesLanguage(_ folderName: String) -> Bool {
        let folderLang = folderName.lowercased()
        if folderLang == requestedLang {
            return true
        }
        if let primary = requestedPrimary, folderLang == primary {
            return true
        }
        return false
    }

    // Find matching .lproj folder URL
    let matchedLproj = lprojDirs.first(where: {
        matchesLanguage($0.deletingPathExtension().lastPathComponent)
    }) ?? lprojDirs.first(where: {
        // fallback: try just primary language if no exact match
        guard let primary = requestedPrimary else { return false }
        return $0.deletingPathExtension().lastPathComponent.lowercased() == primary
    })

    guard let lprojURL = matchedLproj else { return nil }

    let infoPlistStringsURL = lprojURL.appendingPathComponent("InfoPlist.strings")

    guard let dict = NSDictionary(contentsOf: infoPlistStringsURL) as? [String: String], !dict.isEmpty else {
        return nil
    }

    return dict
}

private func specialCaseNameIfAny(for bundle: Bundle) -> String? {
    guard let bid = bundle.bundleIdentifier else { return nil }
    switch bid {
    case "com.apple.Safari":
        return NSLocalizedString("Safari", comment: "Safari")
    case "com.apple.iWork.Pages":
        return NSLocalizedString("Pages", comment: "Pages")
    case "com.apple.iWork.Numbers":
        return NSLocalizedString("Numbers", comment: "Numbers")
    case "com.apple.iWork.Keynote":
        return NSLocalizedString("Keynote", comment: "Keynote")
    default:
        return nil
    }
}

private func specialCaseLocalizedName(for bundle: Bundle, fallback: String) -> String {
    if let name = specialCaseNameIfAny(for: bundle) {
        return name
    }
    return fallback
}
