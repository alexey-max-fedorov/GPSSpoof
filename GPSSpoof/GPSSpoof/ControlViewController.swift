import UIKit
import CoreLocation

// Remote control for the Mac-side helper (GPSSpoofHelper): POSTs new
// coordinates to it, and the helper re-points the running Xcode simulation.
// Also displays the keepalive status that AppDelegate feeds in via showStatus.
final class ControlViewController: UIViewController {
    private let statusLabel = UILabel()
    private let urlField = UITextField()
    private let latField = UITextField()
    private let lonField = UITextField()
    private let applyButton = UIButton(type: .system)
    private let resultLabel = UILabel()

    /// Set by AppDelegate; triggers the system when-in-use permission prompt.
    var onRequestPermission: (() -> Void)?

    private static let urlDefaultsKey = "GPSSpoofHelperURL"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.text = "GPSSpoof\nwaiting for location permission…"
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)

        configure(urlField, placeholder: "helper URL, e.g. http://192.168.1.20:8755",
                  keyboard: .URL)
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.text = UserDefaults.standard.string(forKey: Self.urlDefaultsKey)

        configure(latField, placeholder: "latitude, e.g. 37.3861",
                  keyboard: .numbersAndPunctuation)
        configure(lonField, placeholder: "longitude, e.g. -122.0839",
                  keyboard: .numbersAndPunctuation)

        applyButton.setTitle("Apply location", for: .normal)
        applyButton.titleLabel?.font = .boldSystemFont(ofSize: 18)
        applyButton.addTarget(self, action: #selector(applyTapped), for: .touchUpInside)

        resultLabel.numberOfLines = 0
        resultLabel.textAlignment = .center
        resultLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        resultLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [
            statusLabel, urlField, latField, lonField, applyButton, resultLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    /// Called by AppDelegate whenever CoreLocation authorization changes.
    /// Surfaced as a permission card in the redesigned UI (next task).
    func updateAuthorization(_ status: CLAuthorizationStatus) {}

    /// Called by AppDelegate with keepalive / simulated-fix updates.
    func showStatus(_ text: String) {
        DispatchQueue.main.async { self.statusLabel.text = text }
    }

    private func configure(_ field: UITextField, placeholder: String,
                           keyboard: UIKeyboardType) {
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.keyboardType = keyboard
        field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
    }

    @objc private func dismissKeyboard() { view.endEditing(true) }

    @objc private func applyTapped() {
        view.endEditing(true)
        var base = (urlField.text ?? "").trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/location"), url.scheme?.hasPrefix("http") == true else {
            showResult("enter the helper URL the Mac printed, e.g. http://192.168.1.20:8755")
            return
        }
        guard let lat = Double(latField.text ?? ""), let lon = Double(lonField.text ?? ""),
              (-90...90).contains(lat), (-180...180).contains(lon) else {
            showResult("lat must be -90..90, lon -180..180")
            return
        }
        UserDefaults.standard.set(base, forKey: Self.urlDefaultsKey)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["lat": lat, "lon": lon])

        applyButton.isEnabled = false
        showResult("applying…")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async { self?.applyButton.isEnabled = true }
            if let error = error {
                self?.showResult("could not reach helper: \(error.localizedDescription)\nIs spoof.sh --listen running on the Mac?")
                return
            }
            guard let data = data,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self?.showResult("helper sent an unreadable reply")
                return
            }
            if body["ok"] as? Bool == true {
                let slot = body["slot"] as? String ?? "?"
                self?.showResult(String(format: "applied %.5f, %.5f (slot %@)", lat, lon, slot))
            } else {
                self?.showResult(body["error"] as? String ?? "helper reported an error")
            }
        }.resume()
    }

    private func showResult(_ text: String) {
        DispatchQueue.main.async { self.resultLabel.text = text }
    }
}
