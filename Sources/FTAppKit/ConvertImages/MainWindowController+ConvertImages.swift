import AppKit
import FTFileSystem
import FTFoundation

extension MainWindowController {
    /// Starts the conversion the sheet settled; tests swap it to see what was asked.
    static var runConvertImages: @MainActor (WindowWriteActions, [String], ImageConversionOptions) async -> Void = {
        actions, paths, options in
        _ = await actions.convertImages(paths, options: options)
    }

    /// The formats the sheet offers: those this Mac can write. Tests swap it.
    static var writableImageFormats: @MainActor () -> [ImageFormat] = { ImageFormat.writableHere }

    /// Reads what the sheet needs of the pictures; tests swap it.
    static var readImageInfos: @Sendable ([String]) async -> [ImageInfo?] = { await ImageConverter.infos($0) }

    /// The Convert Images sheet, while it is up.
    var convertImagesSheet: ConvertImagesSheetView? {
        dialogs.lazy.compactMap { $0.panel as? ConvertImagesSheetView }.first
    }

    /// Whether the sheet is up: the panes take no keyboard and the list's shortcuts wait.
    var isConvertImagesOpen: Bool { convertImagesSheet != nil }

    /// `openConvertImagesSheet`, every way in: the menus close; a write running is said instead; nothing but images
    /// opens it. The last choices are read as it opens, and the pictures' sizes read meanwhile.
    func openConvertImagesSheet(_ paths: [String]) {
        AppMenuPresenter.shared.close()
        let actions = writeActions
        if let actions, actions.refuseWhileBusy(.operation(.convertImages)) { return }
        guard !paths.isEmpty, paths.allSatisfy({ ImageConversion.isConvertible(name: NodePath.basename($0)) }),
            let window, convertImagesSheet == nil
        else { return }
        sidebarController.model.clearTypeahead()
        let sheetView = ConvertImagesSheetView(
            sheet: ConvertImagesSheet(
                settings: preferences.convertImagesSettings, count: paths.count,
                formats: Self.writableImageFormats()))
        let scrim = DialogScrim(panel: sheetView, placement: .sheet)
        scrim.setAccessibilityIdentifier("convertImages.scrim")
        sheetView.onCancel = { [weak scrim] in scrim?.dismiss() }
        sheetView.onConvert = { [weak self, weak scrim] settings, remembered in
            scrim?.dismiss()
            self?.updatePreferences { $0.convertImagesSettings = remembered }
            self?.startConvertImages(paths, options: settings.options)
        }
        scrim.present(in: window)
        sheetView.takeKeyboard()
        let read = Self.readImageInfos
        Task { [weak sheetView] in
            let infos = await read(paths)
            sheetView?.read(infos)
        }
    }

    /// A write started meanwhile is said, and the sheet stays closed.
    func startConvertImages(_ paths: [String], options: ImageConversionOptions) {
        guard let actions = writeActions else { return }
        if actions.refuseWhileBusy(.operation(.convertImages)) { return }
        let run = Self.runConvertImages
        Task { await run(actions, paths, options) }
    }
}
