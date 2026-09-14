import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacImagesConvertCore

struct ContentView: View {
    @EnvironmentObject private var queue: ConversionQueue
    @State private var showTrashWarning = false
    @State private var showPrivacy = false
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your images, ready to use.").font(.title2.weight(.semibold))
                    Text("Convert on your Mac. No uploads.").foregroundStyle(.secondary)
                }
                Spacer()
                Text("0.2.2 beta").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                files.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView {
                    settings.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: 350)
            }.frame(maxHeight: .infinity)
            Divider()
            footer.padding(16)
        }
        .toolbar {
            ToolbarItem { Button("Add images", systemImage: "plus") { queue.chooseFiles() } }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    if let url { Task { @MainActor in queue.enqueue([url]) } }
                }
            }
            return true
        }
        .alert("Move originals to Trash?", isPresented: $showTrashWarning) {
            Button("Enable", role: .destructive) { queue.options.moveOriginalToTrash = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only after a converted copy is saved and checked. Files in synced folders may also be removed on other devices.")
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Save as").font(.headline)
                Picker("Output format", selection: $queue.options.format) {
                    ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("What do you need?").font(.headline)
                ForEach(ConversionPurpose.allCases) { purpose in
                    Button {
                        focusedField = nil
                        queue.setup.purpose = purpose
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: queue.setup.purpose == purpose ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(queue.setup.purpose == purpose ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(purpose.rawValue).fontWeight(.medium)
                                Text(description(purpose)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(queue.setup.purpose == purpose ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(queue.setup.purpose == purpose ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12)))
                    }.buttonStyle(.plain)
                }
            }
            if queue.setup.purpose == .resize { resizeControls }
            if queue.setup.purpose == .upload { limitControls }
            if queue.options.format == .jpeg && queue.setup.purpose != .upload {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Image quality").font(.headline)
                    Picker("Image quality", selection: $queue.options.jpegQuality) {
                        ForEach(JPEGQuality.allCases) { quality in
                            Text(quality == .high ? "High — recommended" : quality.rawValue).tag(quality)
                        }
                    }.labelsHidden().frame(maxWidth: .infinity)
                    Text("Higher quality usually creates a larger file.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = queue.validationMessage {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("What will happen", systemImage: "info.circle").font(.caption.weight(.semibold))
                Text(summary).font(.caption).fixedSize(horizontal: false, vertical: true)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            DisclosureGroup("Privacy & originals", isExpanded: $showPrivacy) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Hide where photos were taken", isOn: $queue.options.removeLocation)
                    Text("Removes location data saved inside the file.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Move originals to Trash", isOn: Binding(get: { queue.options.moveOriginalToTrash }, set: {
                        if $0 { showTrashWarning = true } else { queue.options.moveOriginalToTrash = false }
                    }))
                }.padding(.top, 10)
            }
        }.disabled(queue.isRunning)
    }

    private var resizeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Image dimensions").font(.headline)
            Picker("Resize preset", selection: $queue.setup.resizePreset) {
                Text("2048 px longest side — web").tag("2048")
                Text("75% of original width & height").tag("75%")
                Text("50% of original width & height").tag("50%")
                Text("25% of original width & height").tag("25%")
                Text("Custom bounds").tag("Custom")
            }.labelsHidden().frame(maxWidth: .infinity)
            if queue.setup.resizePreset == "Custom" {
                HStack(alignment: .top, spacing: 12) {
                    numberField("Maximum width", text: $queue.setup.width, unit: "px", id: "width")
                    numberField("Maximum height", text: $queue.setup.height, unit: "px", id: "height")
                }
                Text("Fits inside these bounds. Keeps proportions; never stretches or enlarges.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Pixels control width and height. This mode does not set an MB limit.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var limitControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Maximum file size per image").font(.headline)
            Picker("File limit", selection: $queue.setup.limitPreset) {
                Text("500 KB").tag("500 KB"); Text("1 MB").tag("1 MB")
                Text("2 MB — recommended").tag("2 MB"); Text("5 MB").tag("5 MB")
                Text("Custom limit").tag("Custom")
            }.labelsHidden().frame(maxWidth: .infinity)
            if queue.setup.limitPreset == "Custom" {
                numberField("File must be no larger than", text: $queue.setup.limit, unit: queue.setup.unit, id: "limit")
                Picker("Size unit", selection: $queue.setup.unit) {
                    Text("KB").tag("KB"); Text("MB").tag("MB")
                }.pickerStyle(.segmented).labelsHidden()
            }
            Text(queue.options.format == .jpeg
                 ? "Automatic: keeps the original dimensions first, lowers JPG quality, then reduces dimensions only if needed."
                 : "PNG uses lossless compression. The app reduces dimensions if needed to fit your limit.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func numberField(_ label: String, text: Binding<String>, unit: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField("", text: text).labelsHidden().textFieldStyle(.plain)
                    .font(.system(size: 18, design: .monospaced))
                    .focused($focusedField, equals: id).accessibilityLabel(label)
                    .frame(minWidth: 0, maxWidth: .infinity)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).frame(height: 42)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focusedField == id ? Color.accentColor : Color.secondary.opacity(0.55), lineWidth: focusedField == id ? 2 : 1))
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Images (\(queue.jobs.count))").font(.headline)
                Spacer()
                Menu {
                    Button("Add images…") { queue.chooseFiles() }
                    Button("Convert these again") { queue.convertAgain() }
                    Button("Retry failures") { queue.retryFailures() }
                    Button("Clear finished") { queue.clearFinished() }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Image actions") }
                .menuStyle(.borderlessButton).fixedSize().disabled(queue.isRunning)
            }.padding([.horizontal, .top], 20)
            if queue.jobs.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Drop images or folders here").font(.headline)
                    Text("HEIC · JPG · PNG · static WebP").font(.caption).foregroundStyle(.secondary)
                    Button("Add images…") { queue.chooseFiles() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(queue.jobs) { job in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(job.url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                if let info = job.inspection {
                                    Text("Original: \(info.bytesText) · \(info.dimensionsText)").font(.caption).foregroundStyle(.secondary)
                                }
                                jobStatus(job)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(.horizontal, 20)
                }
            }
        }.padding(.bottom, 16).clipped()
    }

    @ViewBuilder private func jobStatus(_ job: ConversionQueue.Job) -> some View {
        switch job.state {
        case .ready: Text("Ready").font(.caption).foregroundStyle(.secondary)
        case .converting: Label("Converting…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.blue)
        case .failed(let error), .skipped(let error):
            Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
        case .completed(let url):
            if let output = job.outputInspection {
                Label("Saved: \(output.bytesText) · \(output.dimensionsText)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.font(.caption)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Save to folder", systemImage: "folder").font(.subheadline.weight(.medium))
                Text(queue.destination?.path ?? "Choose a destination").lineLimit(1).truncationMode(.middle)
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Button(queue.destination == nil ? "Choose folder…" : "Change…") { queue.chooseDestination() }.disabled(queue.isRunning)
            }
            HStack {
                Text(queue.isRunning ? "\(queue.completedCount) saved" : "\(queue.readyCount) ready · Originals \(queue.options.moveOriginalToTrash ? "move to Trash after saving" : "stay in place")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if queue.isRunning {
                    ProgressView(value: queue.progress).frame(width: 90)
                    Button(queue.isPaused ? "Resume" : "Pause") { queue.isPaused.toggle() }
                    Button("Cancel") { queue.cancel() }
                } else if queue.readyCount == 0 && queue.completedCount > 0 {
                    Button("Convert these again") { queue.convertAgain() }
                } else {
                    Button(queue.destination == nil ? "Choose folder to continue…" : "Convert \(queue.readyCount) \(queue.readyCount == 1 ? "image" : "images")") {
                        focusedField = nil
                        queue.start()
                    }.buttonStyle(.borderedProminent).disabled(queue.readyCount == 0 || queue.validationMessage != nil)
                }
            }
            if let message = queue.message { Text(message).font(.caption).foregroundStyle(.red) }
        }
    }

    private func description(_ purpose: ConversionPurpose) -> String {
        switch purpose {
        case .convert: "Change format. Keep the original dimensions."
        case .resize: "Choose smaller pixel dimensions."
        case .upload: "Meet a website's MB or KB upload limit."
        }
    }
    private var summary: String {
        guard let options = try? queue.setup.resolved(from: queue.options) else { return "Check the highlighted values before converting." }
        if let cap = options.sizeCap { return "Each \(options.format.rawValue) will be at most \(cap.label). Dimensions are automatic. If the limit cannot be met, the image is marked as failed." }
        if case .custom(let w, let h) = options.dimensions { return "Fit within \(w) px wide and \(h) px tall. One side may be smaller to keep the photo's proportions. File size may vary." }
        if queue.setup.purpose == .resize { return "Resize to \(options.dimensions.label), keeping proportions. The final MB size depends on the image." }
        return "Keep the original pixel dimensions and save as \(options.format.rawValue). File size may change with the format."
    }
}
