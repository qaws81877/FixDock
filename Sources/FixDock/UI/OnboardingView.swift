// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, language, features, permissions, finish
}

/// First-launch introduction. Closing the window without finishing shows it
/// again next launch. Skip marks it done.
struct OnboardingView: View {
    @State private var step: OnboardingStep = .welcome
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        let strings = l10n.s
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case .welcome:
                AppIconImage(size: 64)
                Text(strings.onboardingWelcomeTitle)
                    .font(.title2.weight(.semibold))
                Text(strings.onboardingWelcomeBody)
                    .fixedSize(horizontal: false, vertical: true)
            case .language:
                Text(strings.onboardingLanguageTitle)
                    .font(.title2.weight(.semibold))
                Text(strings.languageCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker(strings.languageTitle, selection: $l10n.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            case .features:
                Text(strings.onboardingFeaturesTitle)
                    .font(.title2.weight(.semibold))
                Text(strings.onboardingFeaturesBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    FeatureHubList(showsInstallButtons: true)
                }
                .frame(maxHeight: 280)
            case .permissions:
                Text(strings.onboardingPermissionsTitle)
                    .font(.title2.weight(.semibold))
                Text(strings.onboardingPermissionsBody)
                    .fixedSize(horizontal: false, vertical: true)
            case .finish:
                Text(strings.onboardingFinishTitle)
                    .font(.title2.weight(.semibold))
                Text(strings.onboardingFinishBody)
                    .fixedSize(horizontal: false, vertical: true)
                ShortcutCaps(keys: GlobalShortcut.panelDefault.keyCaps)
            }
            Spacer(minLength: 0)
            HStack {
                Button(strings.onboardingSkip) { appDelegate()?.finishOnboarding() }
                Spacer()
                if step != .welcome {
                    Button(strings.onboardingBack) { goBack() }
                }
                if step == .finish {
                    Button(strings.onboardingGetStarted) { appDelegate()?.finishOnboarding() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(strings.onboardingContinue) { goForward() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 480, alignment: .topLeading)
    }

    private func goForward() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    private func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }
}
