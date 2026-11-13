import AppKit
import SwiftUI

/// Hosts the selected tab's editor. Each tab keeps its own NSTextView (inside its `EditorBridge`)
/// so undo history and scroll position survive switching tabs.
struct SQLEditor: NSViewRepresentable {
    let tab: QueryTab
    let fontSize: Double
    let onChange: () -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        let editor = tab.editor
        editor.onChange = onChange
        editor.setFontSize(fontSize)
        if editor.textView.string != tab.sql {
            editor.load(tab.sql)
        }
        let scrollView = editor.scrollView
        if scrollView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            scrollView.frame = container.bounds
            scrollView.autoresizingMask = [.width, .height]
            container.addSubview(scrollView)
        }
    }
}

/// Owns a tab's text view and the editing commands the menus call (comment, format, case…).
@MainActor
final class EditorBridge: NSObject, NSTextViewDelegate {
    weak var tab: QueryTab?
    var onChange: (() -> Void)?

    let textView: SQLTextView
    let scrollView: NSScrollView
    private var fontSize: Double = 13

    override init() {
        // TextKit 1 stack, which the line-number ruler relies on.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        scrollView = NSScrollView()
        super.init()

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.backgroundColor = NSColor(Theme.background)
        textView.insertionPointColor = .white
        textView.selectedTextAttributes = [.backgroundColor: NSColor(Theme.selection)]
        textView.delegate = self
        applyFont()

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(Theme.background)
        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
    }

    // MARK: Model ↔ view

    func load(_ text: String) {
        textView.string = text
        Highlighter.apply(to: textView, fontSize: fontSize)
        scrollView.verticalRulerView?.needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        tab?.sql = textView.string
        Highlighter.apply(to: textView, fontSize: fontSize)
        scrollView.verticalRulerView?.needsDisplay = true
        onChange?()
    }

    func setFontSize(_ size: Double) {
        guard size != fontSize else { return }
        fontSize = size
        applyFont()
        Highlighter.apply(to: textView, fontSize: fontSize)
    }

    private func applyFont() {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: Highlighter.plain]
    }

    // MARK: Queries from the store

    var selectedText: String? {
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }

    var cursor: Int { textView.selectedRange().location }

    func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    func insert(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
        focus()
    }

    /// Replaces everything, undoably.
    func replaceAll(_ text: String) {
        replace(NSRange(location: 0, length: (textView.string as NSString).length), with: text)
    }

    /// Briefly highlights the statement that ⌘↩ is about to run.
    func flash(_ range: NSRange) {
        guard textView.window != nil, NSMaxRange(range) <= (textView.string as NSString).length else { return }
        textView.showFindIndicator(for: range)
    }

    // MARK: Editing commands

    /// ⌘- : adds or removes "-- " at the start of each selected line.
    func toggleComment() {
        let text = textView.string as NSString
        let lines = text.lineRange(for: textView.selectedRange())
        let block = text.substring(with: lines)
        var parts = block.components(separatedBy: "\n")
        let trailingNewline = parts.last == ""
        if trailingNewline { parts.removeLast() }

        let content = parts.filter { !$0.trimmed.isEmpty }
        let allCommented = !content.isEmpty && content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        let changed = parts.map { line -> String in
            guard !line.trimmed.isEmpty else { return line }
            if allCommented {
                guard let range = line.range(of: "--") else { return line }
                var result = line
                let end = result[range.upperBound...].hasPrefix(" ") ? result.index(after: range.upperBound) : range.upperBound
                result.removeSubrange(range.lowerBound..<end)
                return result
            }
            return "-- " + line
        }
        let replacement = changed.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        replace(lines, with: replacement)
        textView.setSelectedRange(NSRange(location: lines.location, length: (replacement as NSString).length))
    }

    func changeCase(upper: Bool) {
        if upper { textView.uppercaseWord(nil) } else { textView.lowercaseWord(nil) }
    }

    /// ⇧⌘K: formats the selection, or the whole editor.
    func format() {
        let range = textView.selectedRange().length > 0
            ? textView.selectedRange()
            : NSRange(location: 0, length: (textView.string as NSString).length)
        let source = (textView.string as NSString).substring(with: range)
        guard !source.trimmed.isEmpty else { return }
        replace(range, with: SQL.format(source))
    }

    /// ⌥⇧↑ / ⌥⇧↓, as in VS Code: copies the current line (or the lines a multi-line selection touches)
    /// above or below. A selection inside one line is copied on its own, straight after (or before) itself.
    /// The cursor moves with the copy going down and stays put going up.
    func duplicate(down: Bool) {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let lines = text.lineRange(for: selection)
        let block = text.substring(with: lines)

        let selectedText = text.substring(with: selection)
        let wholeLines = selection.location == lines.location && selection.length >= block.trimmingCharacters(in: .newlines).utf16.count
        if selection.length > 0, !selectedText.contains(where: \.isNewline), !wholeLines {
            // Part of one line: duplicate just the selected text.
            replace(NSRange(location: NSMaxRange(selection), length: 0), with: selectedText)
            if down { textView.setSelectedRange(NSRange(location: NSMaxRange(selection), length: selection.length)) }
            else { textView.setSelectedRange(selection) }
            return
        }

        // The last line has no newline of its own, so the copy brings one.
        let endsWithNewline = block.hasSuffix("\n")
        let copy = endsWithNewline ? block : (down ? "\n" + block : block + "\n")
        replace(NSRange(location: down ? NSMaxRange(lines) : lines.location, length: 0), with: copy)
        let shift = down ? (copy as NSString).length : 0
        textView.setSelectedRange(NSRange(location: selection.location + shift, length: selection.length))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    private func replace(_ range: NSRange, with text: String) {
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
    }
}

/// Plain-text SQL editing: tab inserts spaces, new lines keep the current indent,
/// and ⌥⇧↑ / ⌥⇧↓ duplicate the line or selection.
final class SQLTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        let arrow = event.specialKey == .upArrow ? false : event.specialKey == .downArrow ? true : nil
        if modifiers == [.option, .shift], let down = arrow, let bridge = delegate as? EditorBridge {
            MainActor.assumeIsolated { bridge.duplicate(down: down) }
            return
        }
        super.keyDown(with: event)
    }

    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let line = text.substring(with: text.lineRange(for: NSRange(location: selectedRange().location, length: 0)))
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(String(indent), replacementRange: selectedRange()) }
    }
}

/// Regex-based colouring: keywords, numbers, `identifiers`, strings and comments (applied in that order,
/// so strings and comments win over anything inside them).
@MainActor
enum Highlighter {
    static let plain = NSColor(white: 0.88, alpha: 1)
    private static let keywordColour = NSColor(red: 0.34, green: 0.67, blue: 0.98, alpha: 1)
    private static let stringColour = NSColor(red: 0.98, green: 0.62, blue: 0.35, alpha: 1)
    private static let numberColour = NSColor(red: 0.55, green: 0.85, blue: 0.55, alpha: 1)
    private static let identifierColour = NSColor(red: 0.78, green: 0.62, blue: 0.98, alpha: 1)
    private static let commentColour = NSColor(white: 0.5, alpha: 1)

    private static let keywordPattern = try! NSRegularExpression(
        pattern: "\\b(" + SQL.keywords.sorted().joined(separator: "|") + ")\\b", options: .caseInsensitive)
    private static let numberPattern = try! NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b")
    private static let identifierPattern = try! NSRegularExpression(pattern: "`[^`]*`")
    private static let stringPattern = try! NSRegularExpression(pattern: #"'(?:[^'\\]|\\.|'')*'?|"(?:[^"\\]|\\.|"")*"?"#)
    private static let commentPattern = try! NSRegularExpression(pattern: #"--\s[^\n]*|--$|#[^\n]*|/\*[\s\S]*?(\*/|$)"#, options: .anchorsMatchLines)

    static func apply(to textView: NSTextView, fontSize: Double) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: plain], range: full)
        // Very large scripts stay plain so typing never lags.
        if storage.length < 300_000 {
            let text = storage.string
            let passes: [(NSRegularExpression, NSColor)] = [
                (keywordPattern, keywordColour), (numberPattern, numberColour), (identifierPattern, identifierColour),
                (stringPattern, stringColour), (commentPattern, commentColour),
            ]
            for (pattern, colour) in passes {
                pattern.enumerateMatches(in: text, range: full) { match, _, _ in
                    if let range = match?.range { storage.addAttribute(.foregroundColor, value: colour, range: range) }
                }
            }
        }
        storage.endEditing()
    }
}

/// Line numbers down the left of the editor.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor(Theme.background).setFill()
        bounds.fill()

        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let firstChar = layout.characterIndexForGlyph(at: glyphs.location)
        // Count lines before the visible area once, then step through the visible lines.
        var line = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: firstChar), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        if firstChar == 0 { line = 1 }

        let font = NSFont.monospacedDigitSystemFont(ofSize: max((textView.font?.pointSize ?? 13) - 2, 9), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.45, alpha: 1)]
        let inset = textView.textContainerInset.height
        let offset = convert(NSPoint.zero, from: textView).y

        var index = firstChar
        while index <= NSMaxRange(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)) && index <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
            let glyph = layout.glyphIndexForCharacter(at: min(lineRange.location, max(text.length - 1, 0)))
            var rect = text.length == 0 ? .zero : layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if text.length > 0, lineRange.location >= text.length { rect = layout.extraLineFragmentRect }
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = rect.minY + inset + offset + (rect.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
            line += 1
            if NSMaxRange(lineRange) == index || lineRange.length == 0 { break }
            index = NSMaxRange(lineRange)
            if index == text.length && !text.hasSuffix("\n") { break }
        }
    }
}
