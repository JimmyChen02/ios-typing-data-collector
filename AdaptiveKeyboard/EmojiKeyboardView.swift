import UIKit

protocol EmojiKeyboardViewDelegate: AnyObject {
    func emojiKeyboard(
        _ view: EmojiKeyboardView,
        didSelect emoji: String,
        at location: CGPoint,
        keyFrame: CGRect
    )
    func emojiKeyboardDidTapLetters(_ view: EmojiKeyboardView)
    func emojiKeyboardDidTapDelete(_ view: EmojiKeyboardView)
    func emojiKeyboardDidTapGlobe(_ view: EmojiKeyboardView)
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
    private var lastTouchLocation: CGPoint = .zero
    private var deleteTimer: Timer?

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
        lettersButton.addTarget(self, action: #selector(handleLetters), for: .touchUpInside)

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.tintColor = .label
        globeButton.addTarget(self, action: #selector(handleGlobe), for: .touchUpInside)

        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.tintColor = .label
        deleteButton.addTarget(self, action: #selector(handleDelete), for: .touchUpInside)
        let deleteHold = UILongPressGestureRecognizer(target: self, action: #selector(handleDeleteHold(_:)))
        deleteHold.minimumPressDuration = 0.42
        deleteButton.addGestureRecognizer(deleteHold)

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
        if recognizer.state == .began {
            lastTouchLocation = recognizer.location(in: self)
        }
    }

    @objc private func handleLetters() {
        delegate?.emojiKeyboardDidTapLetters(self)
    }

    @objc private func handleGlobe() {
        delegate?.emojiKeyboardDidTapGlobe(self)
    }

    @objc private func handleDelete() {
        UIDevice.current.playInputClick()
        delegate?.emojiKeyboardDidTapDelete(self)
    }

    @objc private func handleDeleteHold(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            deleteTimer?.invalidate()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.delegate?.emojiKeyboardDidTapDelete(self)
            }
        case .ended, .cancelled, .failed:
            deleteTimer?.invalidate()
            deleteTimer = nil
        default:
            break
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
        UIDevice.current.playInputClick()
        preferences.noteEmojiUse(emoji)
        delegate?.emojiKeyboard(self, didSelect: emoji, at: lastTouchLocation, keyFrame: frameInView)
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
