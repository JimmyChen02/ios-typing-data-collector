import UIKit

protocol EmojiKeyboardViewDelegate: AnyObject {
    func emojiKeyboard(
        _ view: EmojiKeyboardView,
        didSelect emoji: String,
        gesture: TouchGesture
    )
    func emojiKeyboardDidTapLetters(_ view: EmojiKeyboardView, gesture: TouchGesture)
    func emojiKeyboardDidTapDelete(
        _ view: EmojiKeyboardView,
        gesture: TouchGesture,
        isRepeat: Bool
    )
    func emojiKeyboardDidTapGlobe(_ view: EmojiKeyboardView, gesture: TouchGesture)
    func emojiKeyboard(_ view: EmojiKeyboardView, didCancelActionGesture gesture: TouchGesture)
}

struct EmojiCategory {
    let title: String
    let symbolName: String
    let emoji: [String]
}

/// Emoji page: category-sectioned grid with recents, matching the iOS emoji keyboard shape.
final class EmojiKeyboardView: UIView {
    weak var delegate: EmojiKeyboardViewDelegate?
    var showsGlobeKey = true { didSet { globeButton.isHidden = !showsGlobeKey } }

    private let preferences = SharedKeyboardPreferences.shared
    private var categories: [EmojiCategory] = []
    private var collectionView: UICollectionView!
    private let bottomBar = UIStackView()
    private let categoryScrollView = UIScrollView()
    private let categoryStack = UIStackView()
    private let lettersButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private var selectionGesture: TouchGesture?
    private var actionGestures: [ObjectIdentifier: TouchGesture] = [:]
    private var deleteTimer: Timer?
    private var deleteDidRepeat = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1)
                : UIColor(red: 0.965, green: 0.965, blue: 0.975, alpha: 1)
        }
        buildCollectionView()
        buildBottomBar()
        reloadCategories()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reloadCategories() {
        categories = EmojiCatalog.categories(recents: preferences.recentEmoji)
        collectionView.reloadData()
    }

    var renderedGeometry: [KeyboardKeyGeometry] {
        var geometry: [KeyboardKeyGeometry] = collectionView.indexPathsForVisibleItems
            .sorted()
            .compactMap { indexPath -> KeyboardKeyGeometry? in
            guard indexPath.section < categories.count,
                  indexPath.item < categories[indexPath.section].emoji.count,
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
                return nil
            }
            let emoji = categories[indexPath.section].emoji[indexPath.item]
            return KeyboardKeyGeometry(
                identifier: "emoji:\(indexPath.section):\(indexPath.item)",
                label: emoji,
                frame: CodableRect(collectionView.convert(attributes.frame, to: self))
            )
        }
        let controls: [(String, String, UIButton)] = [
            ("emoji:letters", "ABC", lettersButton),
            ("emoji:globe", "globe", globeButton),
            ("emoji:delete", "delete", deleteButton)
        ]
        geometry += controls.compactMap { control -> KeyboardKeyGeometry? in
            let (identifier, label, button) = control
            guard !button.isHidden else { return nil }
            return KeyboardKeyGeometry(
                identifier: identifier,
                label: label,
                frame: CodableRect(button.convert(button.bounds, to: self))
            )
        }
        return geometry
    }

    private func buildCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        layout.headerReferenceSize = CGSize(width: 0, height: 22)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.showsVerticalScrollIndicator = false
        collectionView.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.reuseIdentifier)
        collectionView.register(
            EmojiSectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: EmojiSectionHeader.reuseIdentifier
        )
        addSubview(collectionView)

        let locator = UILongPressGestureRecognizer(target: self, action: #selector(recordTouchLocation(_:)))
        locator.minimumPressDuration = 0
        locator.cancelsTouchesInView = false
        locator.delegate = self
        collectionView.addGestureRecognizer(locator)
    }

    private func buildBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.axis = .horizontal
        bottomBar.alignment = .fill
        bottomBar.spacing = 6
        addSubview(bottomBar)

        lettersButton.setTitle("ABC", for: .normal)
        lettersButton.titleLabel?.font = .systemFont(ofSize: 15)
        lettersButton.tintColor = .label
        lettersButton.setTitleColor(.label, for: .normal)
        installActionRecognizer(on: lettersButton)

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.tintColor = .label
        installActionRecognizer(on: globeButton)

        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.tintColor = .label
        installActionRecognizer(on: deleteButton)

        categoryScrollView.translatesAutoresizingMaskIntoConstraints = false
        categoryScrollView.showsHorizontalScrollIndicator = false
        categoryStack.axis = .horizontal
        categoryStack.distribution = .fillEqually
        categoryStack.spacing = 2
        categoryStack.translatesAutoresizingMaskIntoConstraints = false
        categoryScrollView.addSubview(categoryStack)

        for (index, category) in EmojiCatalog.allCategoryDescriptors.enumerated() {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: category.symbolName), for: .normal)
            button.tintColor = .secondaryLabel
            button.tag = index
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.addTarget(self, action: #selector(handleCategory(_:)), for: .touchUpInside)
            categoryStack.addArrangedSubview(button)
        }

        bottomBar.addArrangedSubview(lettersButton)
        bottomBar.addArrangedSubview(globeButton)
        bottomBar.addArrangedSubview(categoryScrollView)
        bottomBar.addArrangedSubview(deleteButton)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            bottomBar.heightAnchor.constraint(equalToConstant: 40),

            lettersButton.widthAnchor.constraint(equalToConstant: 44),
            globeButton.widthAnchor.constraint(equalToConstant: 34),
            deleteButton.widthAnchor.constraint(equalToConstant: 40),

            categoryStack.topAnchor.constraint(equalTo: categoryScrollView.topAnchor),
            categoryStack.bottomAnchor.constraint(equalTo: categoryScrollView.bottomAnchor),
            categoryStack.leadingAnchor.constraint(equalTo: categoryScrollView.leadingAnchor),
            categoryStack.trailingAnchor.constraint(equalTo: categoryScrollView.trailingAnchor),
            categoryStack.heightAnchor.constraint(equalTo: categoryScrollView.heightAnchor)
        ])
    }

    @objc private func recordTouchLocation(_ recognizer: UILongPressGestureRecognizer) {
        let phase: TouchPhase
        switch recognizer.state {
        case .began: phase = .began
        case .changed: phase = .moved
        case .ended: phase = .ended
        case .cancelled, .failed: phase = .cancelled
        default: return
        }
        let point = recognizer.location(in: self)
        let target = emojiTarget(at: point)
        let frame = target?.frame?.cgRect
        let local = frame.map { CGPoint(x: point.x - $0.minX, y: point.y - $0.minY) }
        let normalized = frame.flatMap { rect -> CGPoint? in
            guard rect.width != 0, rect.height != 0 else { return nil }
            return CGPoint(
                x: (point.x - rect.minX) / rect.width,
                y: (point.y - rect.minY) / rect.height
            )
        }
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let sample = TouchSample(
            phase: phase,
            wallTimestamp: now,
            monotonicTimestamp: uptime,
            absolutePosition: CodablePoint(point),
            preciseAbsolutePosition: nil,
            localPosition: local.map(CodablePoint.init),
            normalizedPosition: normalized.map(CodablePoint.init),
            target: target
        )
        if phase == .began {
            selectionGesture = TouchGesture(
                samples: [sample],
                initialTarget: target,
                startedAt: now
            )
        } else {
            selectionGesture?.samples.append(sample)
        }
        if phase == .ended || phase == .cancelled {
            selectionGesture?.finalTarget = target
            selectionGesture?.selectedFrame = target?.frame
            selectionGesture?.endedAt = now
            if let start = selectionGesture?.samples.first?.monotonicTimestamp {
                selectionGesture?.durationMilliseconds = max(0, (uptime - start) * 1_000)
            }
            selectionGesture?.wasCancelled = phase == .cancelled
            let initialIdentifier = selectionGesture?.initialTarget?.identifier
            selectionGesture?.didSlide = initialIdentifier != target?.identifier
        }
    }

    private func emojiTarget(at point: CGPoint) -> TouchTarget? {
        let collectionPoint = convert(point, to: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: collectionPoint),
              indexPath.section < categories.count,
              indexPath.item < categories[indexPath.section].emoji.count,
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
            return nil
        }
        let emoji = categories[indexPath.section].emoji[indexPath.item]
        let frame = collectionView.convert(attributes.frame, to: self)
        return TouchTarget(
            identifier: "emoji:\(indexPath.section):\(indexPath.item)",
            key: emoji,
            frame: CodableRect(frame)
        )
    }

    private func installActionRecognizer(on button: UIButton) {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleActionGesture(_:))
        )
        recognizer.minimumPressDuration = 0
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        button.addGestureRecognizer(recognizer)
    }

    private func actionTarget(for button: UIView) -> TouchTarget {
        let frame = button.convert(button.bounds, to: self)
        let identifier: String
        let key: String
        if button === lettersButton {
            identifier = "emojiAction:abc"
            key = "ABC"
        } else if button === globeButton {
            identifier = "emojiAction:globe"
            key = "globe"
        } else {
            identifier = "emojiAction:delete"
            key = "delete"
        }
        return TouchTarget(identifier: identifier, key: key, frame: CodableRect(frame))
    }

    private func actionSample(
        for recognizer: UILongPressGestureRecognizer,
        phase: TouchPhase
    ) -> TouchSample {
        let point = recognizer.location(in: self)
        let target = actionTarget(for: recognizer.view ?? self)
        let frame = target.frame?.cgRect
        let local = frame.map { CGPoint(x: point.x - $0.minX, y: point.y - $0.minY) }
        let normalized = frame.flatMap { rect -> CGPoint? in
            guard rect.width != 0, rect.height != 0 else { return nil }
            return CGPoint(
                x: (point.x - rect.minX) / rect.width,
                y: (point.y - rect.minY) / rect.height
            )
        }
        return TouchSample(
            phase: phase,
            wallTimestamp: Date(),
            monotonicTimestamp: ProcessInfo.processInfo.systemUptime,
            absolutePosition: CodablePoint(point),
            localPosition: local.map(CodablePoint.init),
            normalizedPosition: normalized.map(CodablePoint.init),
            target: target
        )
    }

    private func finalizedActionGesture(
        _ gesture: TouchGesture,
        cancelled: Bool
    ) -> TouchGesture {
        var completed = gesture
        let finalSample = completed.samples.last
        completed.finalTarget = finalSample?.target
        completed.selectedFrame = finalSample?.target?.frame
        completed.endedAt = finalSample?.wallTimestamp ?? Date()
        if let start = completed.samples.first?.monotonicTimestamp,
           let end = finalSample?.monotonicTimestamp {
            completed.durationMilliseconds = max(0, (end - start) * 1_000)
        }
        completed.wasCancelled = cancelled
        completed.didSlide =
            completed.initialTarget?.identifier != completed.finalTarget?.identifier
        return completed
    }

    @objc private func handleActionGesture(_ recognizer: UILongPressGestureRecognizer) {
        let identifier = ObjectIdentifier(recognizer)
        switch recognizer.state {
        case .began:
            let sample = actionSample(for: recognizer, phase: .began)
            actionGestures[identifier] = TouchGesture(
                samples: [sample],
                initialTarget: sample.target,
                startedAt: sample.wallTimestamp
            )
            guard recognizer.view === deleteButton else { return }
            deleteDidRepeat = false
            deleteTimer?.invalidate()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) {
                [weak self, weak recognizer] _ in
                guard let self else { return }
                self.deleteDidRepeat = true
                self.deleteTimer = Timer.scheduledTimer(
                    withTimeInterval: 0.09,
                    repeats: true
                ) { [weak self, weak recognizer] _ in
                    guard let self,
                          let recognizer,
                          let gesture = self.actionGestures[
                            ObjectIdentifier(recognizer)
                          ] else { return }
                    UIDevice.current.playInputClick()
                    self.delegate?.emojiKeyboardDidTapDelete(
                        self,
                        gesture: gesture,
                        isRepeat: true
                    )
                }
            }
        case .changed:
            actionGestures[identifier]?.samples.append(
                actionSample(for: recognizer, phase: .moved)
            )
        case .ended:
            actionGestures[identifier]?.samples.append(
                actionSample(for: recognizer, phase: .ended)
            )
            deleteTimer?.invalidate()
            deleteTimer = nil
            guard let gesture = actionGestures.removeValue(forKey: identifier) else {
                return
            }
            let completed = finalizedActionGesture(gesture, cancelled: false)
            let endedInside = recognizer.view.map {
                $0.bounds.contains(recognizer.location(in: $0))
            } ?? false
            if recognizer.view === lettersButton {
                if endedInside {
                    delegate?.emojiKeyboardDidTapLetters(self, gesture: completed)
                }
            } else if recognizer.view === globeButton {
                if endedInside {
                    delegate?.emojiKeyboardDidTapGlobe(self, gesture: completed)
                }
            } else if !deleteDidRepeat, endedInside {
                UIDevice.current.playInputClick()
                delegate?.emojiKeyboardDidTapDelete(
                    self,
                    gesture: completed,
                    isRepeat: false
                )
            }
            deleteDidRepeat = false
        case .cancelled, .failed:
            actionGestures[identifier]?.samples.append(
                actionSample(for: recognizer, phase: .cancelled)
            )
            deleteTimer?.invalidate()
            deleteTimer = nil
            guard let gesture = actionGestures.removeValue(forKey: identifier) else {
                return
            }
            deleteDidRepeat = false
            delegate?.emojiKeyboard(
                self,
                didCancelActionGesture: finalizedActionGesture(gesture, cancelled: true)
            )
        default: break
        }
    }

    @objc private func handleCategory(_ sender: UIButton) {
        guard sender.tag < categories.count else { return }
        let indexPath = IndexPath(item: 0, section: sender.tag)
        guard collectionView.numberOfItems(inSection: sender.tag) > 0 else { return }
        collectionView.scrollToItem(at: indexPath, at: .top, animated: true)
    }
}

extension EmojiKeyboardView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

extension EmojiKeyboardView: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        categories.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        categories[section].emoji.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: EmojiCell.reuseIdentifier,
            for: indexPath
        ) as! EmojiCell
        cell.configure(with: categories[indexPath.section].emoji[indexPath.item])
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: EmojiSectionHeader.reuseIdentifier,
            for: indexPath
        ) as! EmojiSectionHeader
        header.configure(title: categories[indexPath.section].title)
        return header
    }
}

extension EmojiKeyboardView: UICollectionViewDelegateFlowLayout {
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let columns = max(6, Int(bounds.width / 46))
        let spacing: CGFloat = 4
        let available = bounds.width - 16 - spacing * CGFloat(columns - 1)
        let side = max(32, available / CGFloat(columns))
        return CGSize(width: side, height: side)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        categories[section].emoji.isEmpty ? .zero : CGSize(width: bounds.width, height: 22)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        let emoji = categories[indexPath.section].emoji[indexPath.item]
        let attributes = collectionView.layoutAttributesForItem(at: indexPath)
        let frameInView = attributes.map { collectionView.convert($0.frame, to: self) } ?? .zero
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        var gesture = selectionGesture ?? TouchGesture(
            initialTarget: TouchTarget(
                identifier: "emoji:\(indexPath.section):\(indexPath.item)",
                key: emoji,
                frame: CodableRect(frameInView)
            ),
            startedAt: now
        )
        if gesture.samples.last?.phase != .ended {
            let point = gesture.samples.last?.absolutePosition?.cgPoint
                ?? CGPoint(x: frameInView.midX, y: frameInView.midY)
            let target = TouchTarget(
                identifier: "emoji:\(indexPath.section):\(indexPath.item)",
                key: emoji,
                frame: CodableRect(frameInView)
            )
            gesture.samples.append(
                TouchSample(
                    phase: .ended,
                    wallTimestamp: now,
                    monotonicTimestamp: uptime,
                    absolutePosition: CodablePoint(point),
                    localPosition: CodablePoint(
                        x: Double(point.x - frameInView.minX),
                        y: Double(point.y - frameInView.minY)
                    ),
                    normalizedPosition: frameInView.width > 0 && frameInView.height > 0
                        ? CodablePoint(
                            x: Double((point.x - frameInView.minX) / frameInView.width),
                            y: Double((point.y - frameInView.minY) / frameInView.height)
                        )
                        : nil,
                    target: target
                )
            )
        }
        gesture.finalTarget = gesture.samples.last?.target
        gesture.selectedFrame = CodableRect(frameInView)
        gesture.endedAt = gesture.samples.last?.wallTimestamp ?? now
        if let start = gesture.samples.first?.monotonicTimestamp,
           let end = gesture.samples.last?.monotonicTimestamp {
            gesture.durationMilliseconds = max(0, (end - start) * 1_000)
        }
        gesture.didSlide = gesture.initialTarget?.identifier != gesture.finalTarget?.identifier
        selectionGesture = nil
        UIDevice.current.playInputClick()
        preferences.noteEmojiUse(emoji)
        delegate?.emojiKeyboard(self, didSelect: emoji, gesture: gesture)
    }
}

private final class EmojiCell: UICollectionViewCell {
    static let reuseIdentifier = "EmojiCell"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 30)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            contentView.backgroundColor = isHighlighted
                ? UIColor.label.withAlphaComponent(0.12)
                : .clear
            contentView.layer.cornerRadius = 6
        }
    }

    func configure(with emoji: String) {
        label.text = emoji
    }
}

private final class EmojiSectionHeader: UICollectionReusableView {
    static let reuseIdentifier = "EmojiSectionHeader"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        label.text = title.uppercased()
    }
}

enum EmojiCatalog {
    struct Descriptor {
        let title: String
        let symbolName: String
    }

    static let allCategoryDescriptors: [Descriptor] = [
        Descriptor(title: "Recents", symbolName: "clock"),
        Descriptor(title: "Smileys & People", symbolName: "face.smiling"),
        Descriptor(title: "Animals & Nature", symbolName: "pawprint"),
        Descriptor(title: "Food & Drink", symbolName: "fork.knife"),
        Descriptor(title: "Activity", symbolName: "figure.run"),
        Descriptor(title: "Travel & Places", symbolName: "car"),
        Descriptor(title: "Objects", symbolName: "lightbulb"),
        Descriptor(title: "Symbols", symbolName: "number"),
        Descriptor(title: "Flags", symbolName: "flag")
    ]

    static func categories(recents: [String]) -> [EmojiCategory] {
        var result: [EmojiCategory] = [
            EmojiCategory(
                title: allCategoryDescriptors[0].title,
                symbolName: allCategoryDescriptors[0].symbolName,
                emoji: recents.isEmpty ? defaultRecents : recents
            )
        ]
        let sets = [smileys, animals, food, activity, travel, objects, symbols, flags]
        for (index, set) in sets.enumerated() {
            let descriptor = allCategoryDescriptors[index + 1]
            result.append(
                EmojiCategory(title: descriptor.title, symbolName: descriptor.symbolName, emoji: set)
            )
        }
        return result
    }

    private static let defaultRecents = ["😀", "😂", "❤️", "👍", "🙏", "😊", "🎉", "🔥"]

    private static let smileys = [
        "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃", "😉", "😊",
        "😇", "🥰", "😍", "🤩", "😘", "😗", "😚", "😙", "😋", "😛", "😜", "🤪",
        "😝", "🤗", "🤭", "🤫", "🤔", "🤐", "😐", "😑", "😶", "😏", "😒", "🙄",
        "😬", "😔", "😪", "😴", "😷", "🤒", "🤕", "🥵", "🥶", "😵", "🤯", "🤠",
        "🥳", "😎", "🤓", "🧐", "😕", "😟", "🙁", "😮", "😯", "😲", "😳", "🥺",
        "😦", "😧", "😨", "😰", "😥", "😢", "😭", "😱", "😖", "😣", "😞", "😓",
        "😩", "😫", "🥱", "😤", "😡", "😠", "🤬", "😈", "💀", "💩", "🤡", "👻",
        "👋", "🤚", "✋", "👌", "🤌", "✌️", "🤞", "🤟", "🤘", "👈", "👉", "👆",
        "👇", "👍", "👎", "✊", "👊", "👏", "🙌", "🙏", "💪", "🫶", "👀", "🧠"
    ]

    private static let animals = [
        "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮",
        "🐷", "🐸", "🐵", "🙈", "🙉", "🙊", "🐔", "🐧", "🐦", "🐤", "🦆", "🦅",
        "🦉", "🦇", "🐺", "🐗", "🐴", "🦄", "🐝", "🐛", "🦋", "🐌", "🐞", "🐜",
        "🕷", "🐢", "🐍", "🦎", "🐙", "🦑", "🦀", "🐠", "🐟", "🐬", "🐳", "🦈",
        "🐊", "🐅", "🐆", "🦓", "🦍", "🐘", "🦏", "🐫", "🦒", "🐄", "🐖", "🐑",
        "🌵", "🌲", "🌳", "🌴", "🌱", "🌿", "🍀", "🍁", "🍂", "🍃", "🌸", "🌹",
        "🌺", "🌻", "🌼", "🌷", "🌞", "🌝", "🌚", "⭐️", "🌟", "✨", "⚡️", "🔥"
    ]

    private static let food = [
        "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍈", "🍒",
        "🍑", "🥭", "🍍", "🥥", "🥝", "🍅", "🍆", "🥑", "🥦", "🥬", "🥒", "🌶",
        "🌽", "🥕", "🧄", "🧅", "🥔", "🍠", "🥐", "🥯", "🍞", "🥖", "🧀", "🥚",
        "🍳", "🧇", "🥞", "🥓", "🍔", "🍟", "🍕", "🌭", "🥪", "🌮", "🌯", "🥗",
        "🍝", "🍜", "🍲", "🍛", "🍣", "🍱", "🥟", "🍤", "🍙", "🍚", "🍘", "🍥",
        "🍦", "🍧", "🍨", "🍩", "🍪", "🎂", "🍰", "🧁", "🥧", "🍫", "🍬", "🍭",
        "☕️", "🍵", "🥤", "🧋", "🍺", "🍻", "🥂", "🍷", "🥃", "🍸", "🍹", "🧃"
    ]

    private static let activity = [
        "⚽️", "🏀", "🏈", "⚾️", "🥎", "🎾", "🏐", "🏉", "🥏", "🎱", "🏓", "🏸",
        "🥅", "🏒", "🏑", "🥍", "🏏", "⛳️", "🏹", "🎣", "🤿", "🥊", "🥋", "🎽",
        "🛹", "🛼", "🛷", "⛸", "🥌", "🎿", "⛷", "🏂", "🏋️", "🤼", "🤸", "⛹️",
        "🤺", "🤾", "🏌️", "🏇", "🧘", "🏄", "🏊", "🤽", "🚣", "🧗", "🚴", "🚵",
        "🎯", "🪀", "🪁", "🎮", "🕹", "🎲", "🧩", "♟", "🎭", "🎨", "🎤", "🎧",
        "🎼", "🎹", "🥁", "🎷", "🎺", "🎸", "🪕", "🎻", "🏆", "🥇", "🥈", "🥉"
    ]

    private static let travel = [
        "🚗", "🚕", "🚙", "🚌", "🚎", "🏎", "🚓", "🚑", "🚒", "🚐", "🚚", "🚛",
        "🚜", "🛴", "🚲", "🛵", "🏍", "🛺", "🚨", "🚔", "🚍", "🚝", "🚄", "🚅",
        "🚂", "✈️", "🛫", "🛬", "🚀", "🛸", "🚁", "⛵️", "🚤", "🛥", "🛳", "⛴",
        "🚢", "⚓️", "🗺", "🗽", "🗼", "🏰", "🏯", "🏟", "🎡", "🎢", "🎠", "⛲️",
        "🏖", "🏝", "🏔", "⛰", "🌋", "🏕", "🏠", "🏡", "🏢", "🏬", "🏥", "🏦",
        "🌆", "🌇", "🌉", "🌌", "🌍", "🌎", "🌏", "🌐", "🧭", "☀️", "🌤", "🌧"
    ]

    private static let objects = [
        "⌚️", "📱", "💻", "⌨️", "🖥", "🖨", "🖱", "💽", "💾", "📀", "📷", "📸",
        "📹", "🎥", "📞", "☎️", "📟", "📺", "📻", "🎙", "⏰", "⏱", "⌛️", "🔋",
        "🔌", "💡", "🔦", "🕯", "🧯", "🛢", "💸", "💵", "💳", "🧾", "💎", "⚖️",
        "🔧", "🔨", "🛠", "⛏", "🔩", "⚙️", "🧰", "🧲", "🔫", "💊", "💉", "🩺",
        "🚪", "🛏", "🛋", "🚽", "🚿", "🛁", "🧴", "🧷", "🧹", "🧺", "🔑", "🗝",
        "📦", "📫", "📮", "📝", "📚", "📖", "🔖", "📎", "📌", "✂️", "🖊", "✏️"
    ]

    private static let symbols = [
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❣️", "💕",
        "💞", "💓", "💗", "💖", "💘", "💝", "☮️", "✝️", "☪️", "🕉", "☸️", "✡️",
        "🔯", "🕎", "☯️", "☦️", "🛐", "⛎", "♈️", "♉️", "♊️", "♋️", "♌️", "♍️",
        "♎️", "♏️", "♐️", "♑️", "♒️", "♓️", "🆔", "⚛️", "🉑", "☢️", "☣️", "📴",
        "📳", "🈶", "🈚️", "🈸", "🈺", "🈷️", "✴️", "🆚", "💮", "🉐", "㊙️", "㊗️",
        "🈴", "🈵", "🈹", "🈲", "🅰️", "🅱️", "🆎", "🆑", "🅾️", "🆘", "❌", "⭕️",
        "🛑", "⛔️", "📛", "🚫", "💯", "💢", "♨️", "🚷", "✅", "☑️", "✔️", "➕"
    ]

    private static let flags = [
        "🏳️", "🏴", "🏁", "🚩", "🏳️‍🌈", "🏳️‍⚧️", "🏴‍☠️", "🇦🇺", "🇦🇹", "🇧🇪", "🇧🇷", "🇨🇦",
        "🇨🇳", "🇨🇴", "🇨🇿", "🇩🇰", "🇪🇬", "🇫🇮", "🇫🇷", "🇩🇪", "🇬🇷", "🇭🇰", "🇮🇳", "🇮🇩",
        "🇮🇪", "🇮🇱", "🇮🇹", "🇯🇵", "🇰🇪", "🇰🇷", "🇲🇽", "🇳🇱", "🇳🇿", "🇳🇬", "🇳🇴", "🇵🇰",
        "🇵🇭", "🇵🇱", "🇵🇹", "🇷🇺", "🇸🇦", "🇸🇬", "🇿🇦", "🇪🇸", "🇸🇪", "🇨🇭", "🇹🇭", "🇹🇷",
        "🇺🇦", "🇦🇪", "🇬🇧", "🇺🇸", "🇻🇳"
    ]
}
