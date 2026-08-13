import SwiftUI
import SwiftData
import UIKit

struct ParticipantSetupView: View {
    @Environment(\.modelContext) private var modelContext
    var sessionManager: SessionManager

    @State private var selectedRole: StudyRole? = nil
    @State private var route: SetupRoute = .welcome
    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var ageText: String = ""
    @State private var email: String = ""
    @State private var dominantHand: DominantHand = .right
    @State private var sex: ParticipantSex = .preferNotToSay
    @State private var typingPosturePreference: TypingPosturePreference = .mixed
    @State private var consentDataShare = false
    @State private var consentVideoShare = false
    @State private var researcherSessionsPerHand = 4
    @State private var randomizationSeed: Int = Int(Date().timeIntervalSince1970)
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @FocusState private var focusedField: SetupField?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.08, blue: 0.15),
                        Color(red: 0.09, green: 0.13, blue: 0.24),
                        Color(red: 0.02, green: 0.05, blue: 0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Circle()
                    .fill(Color.blue.opacity(0.18))
                    .frame(width: 250, height: 250)
                    .blur(radius: 30)
                    .offset(x: 120, y: -250)

                Circle()
                    .fill(Color.cyan.opacity(0.14))
                    .frame(width: 260, height: 260)
                    .blur(radius: 36)
                    .offset(x: -130, y: 260)

                VStack(spacing: 16) {
                    topTitleBar

                    ZStack {
                        switch route {
                        case .welcome:
                            welcomePage
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))
                        case .participantIntro:
                            participantIntroPage
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))
                        case .participantDemographics:
                            demographicsPage
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))
                        case .participantConsent:
                            consentPage
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))
                        case .participantPosture:
                            posturePage
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))
                        case .participantReview:
                            participantReviewPage
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))
                        case .researcherConfig:
                            researcherPage
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))
                        }
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.9), value: route)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Adaptive Keyboard Study")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissKeyboard() }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            ) { notification in
                if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    // Capture this device's real system keyboard once so the
                    // in-app keyboard can match it across iPhone models.
                    SystemKeyboardMetrics.recordSystemKeyboardFrame(frame)
                    sessionManager.measuredKeyboardHeight = SystemKeyboardMetrics.totalDockedHeight()
                    sessionManager.safeAreaBottom = SystemKeyboardMetrics.bottomSafeAreaInset()
                }
            }
            .onChange(of: route) { _, _ in
                dismissKeyboard()
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var topTitleBar: some View {
        VStack(spacing: 4) {
            Text("Adaptive Keyboard")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("User Study App")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
        }
    }

    private var welcomePage: some View {
        setupCard {
            VStack(spacing: 18) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 42))
                    .foregroundColor(.white)

                Text("Welcome")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("This app runs a two-phase adaptive typing study. Choose your role to continue.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.88))

                VStack(spacing: 12) {
                    roleButton(
                        title: "I am a Participant",
                        subtitle: "Onboarding, consent, and guided Phase A/B sessions",
                        color: .blue
                    ) {
                        selectedRole = .participant
                        route = .participantIntro
                    }

                    roleButton(
                        title: "I am a Researcher",
                        subtitle: "Configure protocol, run sessions, inspect analytics",
                        color: .indigo
                    ) {
                        selectedRole = .researcher
                        route = .researcherConfig
                    }
                }
            }
        }
    }

    private var participantIntroPage: some View {
        setupCard {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(
                    title: "About This Study",
                    subtitle: "Please read this before continuing."
                )

                Text("You will complete a two-phase typing study to compare a baseline keyboard with an adaptive Gaussian keyboard.")
                    .foregroundColor(.white.opacity(0.9))
                Text("Each phase has 12 sessions of one minute each, with left-hand, right-hand, and both-hands posture trials in shuffled order.")
                    .foregroundColor(.white.opacity(0.9))
                Text("Your typing behavior and motion signals are used only for research.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))

                Text("Do you want to participate in this study?")
                    .font(.headline)
                    .foregroundColor(.white)

                HStack(spacing: 10) {
                    Button("Not now") {
                        selectedRole = nil
                        route = .welcome
                    }
                    .buttonStyle(.bordered)

                    Button("Yes, continue") {
                        route = .participantDemographics
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var demographicsPage: some View {
        setupCard {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader(title: "Demographics", subtitle: "Please fill in each field.")

                labeledField("First name") {
                    TextField("First name", text: $firstName)
                        .setupField()
                        .textInputAutocapitalization(.words)
                        .focused($focusedField, equals: .firstName)
                }
                labeledField("Last name") {
                    TextField("Last name", text: $lastName)
                        .setupField()
                        .textInputAutocapitalization(.words)
                        .focused($focusedField, equals: .lastName)
                }
                labeledField("Email") {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .setupField()
                        .focused($focusedField, equals: .email)
                }
                labeledField("Age") {
                    TextField("Age", text: $ageText)
                        .keyboardType(.numberPad)
                        .setupField()
                        .focused($focusedField, equals: .age)
                }

                optionList(
                    title: "Gender",
                    selection: $sex,
                    options: ParticipantSex.allCases.map { ($0, $0.displayName) }
                )
                optionList(
                    title: "Dominant writing hand",
                    selection: $dominantHand,
                    options: DominantHand.allCases.map { ($0, $0.displayName) }
                )
                optionList(
                    title: "Dominant / usual typing hand",
                    selection: $typingPosturePreference,
                    options: TypingPosturePreference.formCases.map { ($0, $0.displayName) }
                )

                onboardingNav(
                    backLabel: "Back",
                    nextLabel: "Next",
                    onBack: {
                        dismissKeyboard()
                        route = .participantIntro
                    },
                    onNext: {
                        dismissKeyboard()
                        guard !firstName.trimmingCharacters(in: .whitespaces).isEmpty else {
                            showError(message: "First name is required.")
                            return
                        }
                        guard Int(ageText) != nil else {
                            showError(message: "Please enter a valid age.")
                            return
                        }
                        route = .participantConsent
                    }
                )
            }
        }
    }

    private var consentPage: some View {
        setupCard {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(title: "Consent", subtitle: "Review and confirm permissions.")
                Toggle("I consent to share my typing data with the research team.", isOn: $consentDataShare)
                    .tint(.blue)
                Toggle("I consent to front-camera photos of how I hold the phone while typing.", isOn: $consentVideoShare)
                    .tint(.blue)
                Text("The front camera records during each session so we can see left-hand, right-hand, and both-hands posture. No public release. Data is shared only with the authorized research team.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))

                onboardingNav(
                    backLabel: "Back",
                    nextLabel: "Next",
                    onBack: { route = .participantDemographics },
                    onNext: {
                        guard consentDataShare, consentVideoShare else {
                            showError(message: "Data-sharing and front-camera consent are required to continue.")
                            return
                        }
                        route = .participantPosture
                    }
                )
            }
        }
    }

    private var posturePage: some View {
        setupCard {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(
                    title: "How to sit.",
                    subtitle: "Follow this posture for every session."
                )
                Text("Sit upright in a chair with your back straight. Hold the phone with the hand shown for each session. Keep your arm up. Don't rest it on a desk or table, and don't lean on anything.")
                    .foregroundColor(.white.opacity(0.9))

                HowToSitDiagrams()

                onboardingNav(
                    backLabel: "Back",
                    nextLabel: "Got it",
                    onBack: { route = .participantConsent },
                    onNext: { route = .participantReview }
                )
            }
        }
    }

    private var participantReviewPage: some View {
        setupCard {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(title: "Ready to Start", subtitle: "Confirm and launch participant protocol.")

                Group {
                    summaryRow("Participant", "\(firstName) \(lastName)")
                    summaryRow("Age", ageText)
                    summaryRow("Gender", sex.displayName)
                    summaryRow("Dominant writing hand", dominantHand.displayName)
                    summaryRow("Dominant / usual typing hand", typingPosturePreference.displayName)
                    summaryRow("Data consent", consentDataShare ? "Granted" : "Missing")
                    summaryRow("Camera consent", consentVideoShare ? "Granted" : "Missing")
                    summaryRow("Device", DeviceInfo.modelName)
                    summaryRow("Screen", "\(Int(DeviceInfo.screenWidthPt)) x \(Int(DeviceInfo.screenHeightPt)) pt")
                }
                .foregroundColor(.white)

                HStack(spacing: 10) {
                    Button("Back") {
                        route = .participantPosture
                    }
                    .buttonStyle(.bordered)

                    Button("Start Participant Study") {
                        dismissKeyboard()
                        startParticipantStudy()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var researcherPage: some View {
        setupCard {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(title: "Researcher Configuration", subtitle: "Set protocol before launching.")
                Stepper(value: $researcherSessionsPerHand, in: 1...10) {
                    HStack {
                        Text("Sessions per hand / phase").foregroundColor(.white)
                        Spacer()
                        Text("\(researcherSessionsPerHand)")
                            .foregroundColor(.white.opacity(0.8))
                            .monospacedDigit()
                    }
                }
                Stepper(value: $randomizationSeed, in: 1...9_999_999) {
                    HStack {
                        Text("Randomization seed").foregroundColor(.white)
                        Spacer()
                        Text("\(randomizationSeed)")
                            .foregroundColor(.white.opacity(0.8))
                            .monospacedDigit()
                    }
                }
                Text("Total sessions: \(researcherSessionsPerHand * 3 * 2)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))

                HStack(spacing: 10) {
                    Button("Back") {
                        selectedRole = nil
                        route = .welcome
                    }
                    .buttonStyle(.bordered)

                    Button("Start Researcher Run") {
                        startResearcherStudy()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var readyForParticipantStart: Bool {
        let hasName = !firstName.trimmingCharacters(in: .whitespaces).isEmpty
        let hasAge = Int(ageText) != nil
        return hasName && hasAge && consentDataShare && consentVideoShare
    }

    @ViewBuilder
    private func setupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func labeledField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
            content()
        }
    }

    private func optionList<T: Hashable>(
        title: String,
        selection: Binding<T>,
        options: [(T, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
            VStack(spacing: 8) {
                ForEach(options, id: \.1) { value, label in
                    Button {
                        selection.wrappedValue = value
                    } label: {
                        HStack {
                            Text(label)
                                .foregroundColor(.white)
                            Spacer()
                            if selection.wrappedValue == value {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selection.wrappedValue == value
                                      ? Color.blue.opacity(0.55)
                                      : Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func dismissKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func pageHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.white)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.white.opacity(0.75))
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .fontWeight(.semibold)
            Spacer()
            Text(value.isEmpty ? "-" : value)
                .foregroundColor(.white.opacity(0.85))
        }
        .font(.subheadline)
    }

    private func roleButton(
        title: String,
        subtitle: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .fontWeight(.semibold)
                Text(subtitle)
                    .font(.caption)
                    .opacity(0.9)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(color.opacity(0.78))
            )
        }
    }

    private func onboardingNav(
        backLabel: String,
        nextLabel: String,
        onBack: @escaping () -> Void,
        onNext: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Button(backLabel, action: onBack)
                .buttonStyle(.bordered)
            Button(nextLabel, action: onNext)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Start flows

    private func startParticipantStudy() {
        dismissKeyboard()
        guard readyForParticipantStart else {
            showError(message: "Please complete demographics and required consent before starting.")
            return
        }
        // Let the system keyboard finish dismissing before swapping the root
        // view. Leaving a UITextField first-responder during that swap freezes
        // hit-testing (TUIKeyplane constraint / gesture-gate timeout).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let participant = self.buildParticipant()
            self.modelContext.insert(participant)
            self.sessionManager.configure(modelContext: self.modelContext)
            self.sessionManager.startStudy(
                participant: participant,
                totalSessions: nil,
                design: .classicAndAdaptive,
                role: .participant,
                sessionsPerHandPerPhase: 4,
                randomizationSeed: self.randomizationSeed,
                initialTopic: .weekdayMorning
            )
        }
    }

    private func startResearcherStudy() {
        dismissKeyboard()
        let participant = buildParticipant(defaultFirstName: "Researcher")
        modelContext.insert(participant)
        sessionManager.configure(modelContext: modelContext)
        sessionManager.startStudy(
            participant: participant,
            totalSessions: nil,
            design: .classicAndAdaptive,
            role: .researcher,
            sessionsPerHandPerPhase: researcherSessionsPerHand,
            randomizationSeed: randomizationSeed,
            initialTopic: .weekdayMorning
        )
    }

    private func buildParticipant(defaultFirstName: String = "Participant") -> Participant {
        let fn = firstName.trimmingCharacters(in: .whitespaces)
        let ln = lastName.trimmingCharacters(in: .whitespaces)
        let age: Int? = Int(ageText)
        return Participant(
            firstName: fn.isEmpty ? defaultFirstName : fn,
            lastName: ln.isEmpty ? "" : ln,
            age: age,
            dominantHand: dominantHand,
            sex: sex,
            email: email.trimmingCharacters(in: .whitespaces),
            consentDataShare: consentDataShare,
            consentVideoShare: consentVideoShare,
            typingPosturePreference: typingPosturePreference,
            deviceModel: DeviceInfo.modelName,
            systemVersion: DeviceInfo.systemVersion,
            screenWidthPt: DeviceInfo.screenWidthPt,
            screenHeightPt: DeviceInfo.screenHeightPt,
            appVersion: DeviceInfo.appVersion
        )
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}

private enum SetupField {
    case firstName, lastName, email, age
}

private enum SetupRoute {
    case welcome
    case participantIntro
    case participantDemographics
    case participantConsent
    case participantPosture
    case participantReview
    case researcherConfig
}

private extension View {
    func setupField() -> some View {
        self
            .autocorrectionDisabled()
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
            )
            .foregroundColor(.white)
    }
}
