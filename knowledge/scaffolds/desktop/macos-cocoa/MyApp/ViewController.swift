import Cocoa

class ViewController: NSViewController {

    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var actionButton: NSButton!
    @IBOutlet weak var outputLabel: NSTextField!

    private var clickCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        titleLabel?.stringValue = "Welcome to MyApp"
        outputLabel?.stringValue = ""
    }

    override var representedObject: Any? {
        didSet {
            // Update the view when representedObject changes
        }
    }

    @IBAction func actionButtonClicked(_ sender: NSButton) {
        clickCount += 1
        let suffix = clickCount == 1 ? "time" : "times"
        outputLabel.stringValue = "Button clicked \(clickCount) \(suffix)."
    }
}
