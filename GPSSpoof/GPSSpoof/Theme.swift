import UIKit

/// headliner.studio palette: pure black surfaces with a single gold accent.
enum Theme {
    static let background = UIColor(hex: 0x000000)
    static let cardSurface = UIColor(hex: 0x0A0A0A)
    static let fieldSurface = UIColor(hex: 0x111111)
    static let surfaceBorder = UIColor(hex: 0x1A1A1A)
    static let gold = UIColor(hex: 0xC9A84C)
    static let goldBright = UIColor(hex: 0xD4B65E)
    static let textPrimary = UIColor(hex: 0xFFFFFF)
    static let textSecondary = UIColor(hex: 0xA0A0A0)
    static let textTertiary = UIColor(hex: 0x666666)

    /// Serif display font (the system New York face) for the wordmark.
    static func serifFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func goldButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.setTitleColor(.black, for: .normal)
        button.backgroundColor = gold
        button.layer.cornerRadius = 10
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        return button
    }

    static func outlineButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.setTitleColor(gold, for: .normal)
        button.backgroundColor = .clear
        button.layer.cornerRadius = 10
        button.layer.borderWidth = 1
        button.layer.borderColor = gold.withAlphaComponent(0.6).cgColor
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    static func field(placeholder: String, keyboard: UIKeyboardType) -> UITextField {
        let field = UITextField()
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: textTertiary])
        field.textColor = textPrimary
        field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        field.keyboardType = keyboard
        field.backgroundColor = fieldSurface
        field.layer.cornerRadius = 10
        field.layer.borderWidth = 1
        field.layer.borderColor = surfaceBorder.cgColor
        field.heightAnchor.constraint(equalToConstant: 44).isActive = true
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 44))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 44))
        field.rightViewMode = .always
        return field
    }

    static func card() -> UIView {
        let view = UIView()
        view.backgroundColor = cardSurface
        view.layer.cornerRadius = 12
        view.layer.borderWidth = 1
        view.layer.borderColor = surfaceBorder.cgColor
        return view
    }
}

extension UIColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0)
    }
}
