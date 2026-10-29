// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

/// Export settings are edited as one undoable document change. The draft
/// stays local until Done, so scrubbing the slider does not fill the undo stack.
struct RecorderExportSpeedControl: View {
    @ObservedObject var model: RecorderEditorModel
    @ObservedObject private var l10n = L10n.shared
    @State private var isPresented = false
    @State private var draftSpeed = 1.0

    private var strings: Strings { l10n.s }

    private func label(_ speed: Double) -> String {
        speed.formatted(.number.locale(Locale(identifier: l10n.language.rawValue))
            .precision(.fractionLength(0...2))) + "×"
    }

    var body: some View {
        Button {
            draftSpeed = model.document.exportTiming.speed
            isPresented = true
        } label: {
            Label(label(model.document.exportTiming.speed), systemImage: "speedometer")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help(strings.recorderEditorExportSpeed)
        .accessibilityLabel(strings.recorderEditorExportSpeed)
        .accessibilityValue(label(model.document.exportTiming.speed))
        .disabled(model.isExporting)
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 14) {
                Text(strings.recorderEditorExportSpeed)
                    .font(.headline)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    ForEach(RecorderExportTiming.presets, id: \.self) { speed in
                        Button {
                            draftSpeed = speed
                        } label: {
                            Text(label(speed))
                                .fontWeight(abs(draftSpeed - speed) < 0.001 ? .bold : .regular)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Stepper(value: $draftSpeed, in: RecorderExportTiming.speedRange, step: 0.01) {
                    HStack {
                        Text(strings.recorderEditorExportCustom)
                        Spacer()
                        Text(label(draftSpeed)).monospacedDigit()
                    }
                }
                .accessibilityValue(label(draftSpeed))
                Slider(value: $draftSpeed, in: RecorderExportTiming.speedRange, step: 0.01)
                    .accessibilityLabel(strings.recorderEditorExportCustom)
                    .accessibilityValue(label(draftSpeed))
                HStack {
                    Text(label(RecorderExportTiming.speedRange.lowerBound))
                    Spacer()
                    Text(label(RecorderExportTiming.speedRange.upperBound))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Text(strings.recorderEditorExportDuration)
                    Spacer()
                    Text(RecorderSupport.elapsedLabel(seconds: Int(
                        RecorderExportTiming(speed: draftSpeed)
                            .outputTime(forSourceTime: model.outputDuration).rounded())))
                        .monospacedDigit()
                }
                Text(strings.recorderEditorExportPreviewNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button(l10n.s.recorderEditorCancelButton, role: .cancel) {
                        isPresented = false
                    }
                    Button(l10n.s.screenshotScrollingDone) {
                        var next = model.document
                        next.exportSpeed = (draftSpeed * 100).rounded() / 100
                        model.document = next
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: 320)
            .disabled(model.isExporting)
        }
    }
}
