import Cocoa

extension SettingsWindowController {
    func buildPluginsPage() -> NSView {
        let heading = makeSectionHeading(L("plugins.title"))
        let intro = NSTextField(wrappingLabelWithString: L("plugins.intro"))
        intro.font = NSFont.appFont(.callout)
        intro.textColor = .secondaryLabelColor

        pluginSourceField = NSTextField()
        pluginSourceField.placeholderString = L("plugins.source")
        pluginSourceField.translatesAutoresizingMaskIntoConstraints = false
        pluginSourceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 370).isActive = true
        let choose = NSButton(title: L("plugins.choose"), target: self, action: #selector(choosePluginFile))
        let inspect = NSButton(title: L("plugins.inspect"), target: self, action: #selector(inspectPluginSource))
        let sourceRow = NSStackView(views: [pluginSourceField, choose, inspect])
        sourceRow.orientation = .horizontal
        sourceRow.alignment = .centerY
        sourceRow.spacing = 8

        pluginPreviewLabel = NSTextField(wrappingLabelWithString: "")
        pluginPreviewLabel.font = NSFont.appFont(.subheadline)
        pluginPreviewLabel.textColor = .secondaryLabelColor
        pluginInstallButton = NSButton(title: L("plugins.install"), target: self,
                                       action: #selector(installPreviewedPlugin))
        pluginInstallButton.isEnabled = false

        pluginListStack = NSStackView()
        pluginListStack.orientation = .vertical
        pluginListStack.alignment = .leading
        pluginListStack.spacing = 18
        updatePluginsSection(force: true)

        let stack = NSStackView(views: [heading, intro, sourceRow, pluginPreviewLabel,
                                        pluginInstallButton, pluginListStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        return stack
    }

    func updatePluginsSection(force: Bool = false) {
        guard pluginListStack != nil else { return }
        let records = DisplayPlugins.shared.records
        let signature = records.keys.sorted().map { id in
            "\(id):\(records[id]?.info["version"] as? String ?? ""):"
                + "\(records[id]?.fetchedAt?.timeIntervalSince1970 ?? 0):\(records[id]?.error ?? "")"
        }.joined(separator: "|")
        guard force || signature != pluginsSignature else { return }
        pluginsSignature = signature
        pluginSettingsFields.removeAll()
        pluginListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if records.isEmpty {
            pluginListStack.addArrangedSubview(NSTextField(labelWithString: L("plugins.none")))
            return
        }
        for id in records.keys.sorted() {
            guard let record = records[id] else { continue }
            let info = record.info
            let name = info["name"] as? String ?? id
            let version = info["version"] as? String ?? ""
            let title = makeSectionHeading("\(name)  \(version)")
            let origin = info["sourceOrigin"] as? String ?? "?"
            let author = info["author"] as? String ?? "?"
            let detail = NSTextField(wrappingLabelWithString:
                L("plugins.detail", id, author, origin))
            detail.font = NSFont.appFont(.subheadline)
            detail.textColor = .secondaryLabelColor
            let attribution = info["attribution"] as? String ?? ""
            let credit = NSTextField(wrappingLabelWithString: attribution)
            credit.font = NSFont.appFont(.subheadline)
            credit.textColor = .secondaryLabelColor
            let statusText: String
            if let error = record.error {
                statusText = L("plugins.fetchError", error)
            } else if let fetched = record.fetchedAt {
                statusText = L("plugins.updated", DateFormatter.localizedString(
                    from: fetched, dateStyle: .short, timeStyle: .short))
            } else {
                statusText = L("plugins.waiting")
            }
            let status = NSTextField(labelWithString: statusText)
            status.font = NSFont.appFont(.subheadline)
            status.textColor = record.error == nil ? .secondaryLabelColor : .systemOrange
            var fields: [String: NSTextField] = [:]
            var rows: [NSView] = [title, detail, credit, status]
            for spec in info["settingsSpec"] as? [[String: Any]] ?? [] {
                guard let key = spec["key"] as? String else { continue }
                let label = spec["label"] as? String ?? key
                let value = record.settings[key]
                let field = NSTextField(string: value.map { "\($0)" } ?? "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.widthAnchor.constraint(equalToConstant: 220).isActive = true
                rows.append(twoColumnRow(label, field))
                fields[key] = field
            }
            pluginSettingsFields[id] = fields
            let save = NSButton(title: L("plugins.save"), target: self,
                                action: #selector(savePluginSettings(_:)))
            save.identifier = NSUserInterfaceItemIdentifier(id)
            let remove = NSButton(title: L("plugins.remove"), target: self,
                                  action: #selector(removeInstalledPlugin(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(id)
            let actions = NSStackView(views: [save, remove])
            actions.orientation = .horizontal
            actions.spacing = 8
            rows.append(actions)
            let group = NSStackView(views: rows)
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 8
            pluginListStack.addArrangedSubview(group)
        }
    }

    @objc private func choosePluginFile() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedFileTypes = ["aimplugin"]
        guard picker.runModal() == .OK, let url = picker.url else { return }
        pluginSourceField.stringValue = url.path
        inspectPluginSource()
    }

    @objc private func inspectPluginSource() {
        let source = pluginSourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        pluginPreview = nil
        pluginInstallButton.isEnabled = false
        guard !source.isEmpty else { return }
        pluginPreviewLabel.stringValue = L("plugins.inspecting")
        DisplayPlugins.shared.inspect(source: source) { [weak self] result in
            guard let self = self, self.pluginSourceField.stringValue == source else { return }
            switch result {
            case .success(let info):
                self.pluginPreview = info
                let name = info["name"] as? String ?? "?"
                let author = info["author"] as? String ?? "?"
                let origin = info["sourceOrigin"] as? String ?? "?"
                let hash = info["sha256"] as? String ?? "?"
                self.pluginPreviewLabel.stringValue = L("plugins.preview", name, author, origin,
                                                         String(hash.prefix(16)))
                self.pluginInstallButton.isEnabled = true
            case .failure(let error):
                self.pluginPreviewLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func installPreviewedPlugin() {
        guard let hash = pluginPreview?["sha256"] as? String else { return }
        let source = pluginSourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        pluginInstallButton.isEnabled = false
        pluginPreviewLabel.stringValue = L("plugins.installing")
        DisplayPlugins.shared.install(source: source, expectedSHA256: hash) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let info):
                self.pluginPreview = nil
                self.pluginPreviewLabel.stringValue = L("plugins.installed", info["name"] as? String ?? "Plugin")
                self.updatePluginsSection(force: true)
                self.updateViewsSection(force: true)
            case .failure(let error):
                self.pluginPreviewLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func savePluginSettings(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let record = DisplayPlugins.shared.records[id],
              let fields = pluginSettingsFields[id] else { return }
        var values = record.settings
        for spec in record.info["settingsSpec"] as? [[String: Any]] ?? [] {
            guard let key = spec["key"] as? String, let field = fields[key] else { continue }
            if spec["kind"] as? String == "number" {
                guard let number = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")) else {
                    pluginPreviewLabel.stringValue = L("plugins.invalidNumber", key)
                    return
                }
                values[key] = number
            } else {
                values[key] = field.stringValue
            }
        }
        do {
            try DisplayPlugins.shared.saveSettings(id: id, values: values)
            pluginPreviewLabel.stringValue = L("plugins.saved")
        } catch {
            pluginPreviewLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func removeInstalledPlugin(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let alert = NSAlert()
        alert.messageText = L("plugins.removeTitle")
        alert.informativeText = L("plugins.removeDetail", DisplayPlugins.shared.label(for: DisplayPlugins.prefix + id))
        alert.addButton(withTitle: L("plugins.remove"))
        alert.addButton(withTitle: L("plugins.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try DisplayPlugins.shared.remove(id: id)
            let views = Settings.shared.displayViews.map {
                $0 == DisplayPlugins.prefix + id ? Settings.clockView : $0
            }
            monitor?.updateDisplayViews(views)
            updatePluginsSection(force: true)
            updateViewsSection(force: true)
        } catch {
            pluginPreviewLabel.stringValue = error.localizedDescription
        }
    }
}
