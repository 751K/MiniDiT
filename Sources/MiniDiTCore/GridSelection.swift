import Foundation

/// 和访达一样的选择逻辑：单击、⌘ 单击、⇧ 单击、方向键、框选、全选。
/// 只处理数据，界面把点击 / 按键翻译成这里的调用。
public struct GridSelection<ID: Hashable>: Equatable {
    public enum Modifier: Sendable { case none, command, shift }
    public enum Direction: Sendable { case left, right, up, down }

    /// 当前显示的顺序（从上到下、从左到右）。
    public private(set) var order: [ID] = []
    private var index: [ID: Int] = [:]
    public private(set) var selected: Set<ID> = []
    /// ⇧ 连选的起点。
    public private(set) var anchor: ID?
    /// 键盘焦点（方向键从这里移动）。
    public private(set) var focus: ID?
    /// 上一次 ⇧ 连选加进来的范围（再次 ⇧ 时先撤掉它，和访达一致）。
    private var lastRange: Set<ID> = []
    /// 框选开始时已经选中的内容。
    private var boxBase: Set<ID>?
    private var boxToggles = false

    public init() {}

    /// 显示内容变了（筛选、换日期）：保留选择，只更新顺序。
    public mutating func setOrder(_ ids: [ID]) {
        order = ids
        index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        if let f = focus, index[f] == nil { focus = nil }
        if let a = anchor, index[a] == nil { anchor = nil; lastRange = [] }
    }

    public func contains(_ id: ID) -> Bool { selected.contains(id) }

    // MARK: 点击

    public mutating func click(_ id: ID, _ modifier: Modifier = .none) {
        switch modifier {
        case .none:
            selected = [id]
            anchor = id; focus = id; lastRange = []
        case .command:
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id; focus = id; lastRange = []
        case .shift:
            extend(to: id)
        }
    }

    private mutating func extend(to id: ID) {
        guard let a = anchor, let ia = index[a], let ib = index[id] else {
            click(id, .none)
            return
        }
        let range = Set(order[min(ia, ib)...max(ia, ib)])
        selected.subtract(lastRange.subtracting([a]))
        selected.formUnion(range)
        lastRange = range
        focus = id
    }

    // MARK: 键盘

    /// 方向键：columns 是每行的格数。extend = 按住 ⇧。
    public mutating func move(_ direction: Direction, columns: Int, extend: Bool = false) {
        guard !order.isEmpty else { return }
        let cols = max(1, columns)
        let current = focus.flatMap { index[$0] }
        let next: Int
        if let current {
            switch direction {
            case .left: next = max(0, current - 1)
            case .right: next = min(order.count - 1, current + 1)
            case .up: next = current - cols >= 0 ? current - cols : current
            case .down: next = current + cols < order.count ? current + cols : order.count - 1
            }
        } else {
            next = direction == .left || direction == .up ? order.count - 1 : 0
        }
        let id = order[next]
        if extend {
            if anchor == nil { anchor = focus ?? id }
            self.extend(to: id)
        } else {
            click(id, .none)
        }
    }

    /// 只移动焦点（预览翻页用），不改变选择。
    public mutating func setFocus(_ id: ID) {
        guard index[id] != nil else { return }
        focus = id
        anchor = id
        lastRange = []
    }

    public mutating func selectAll() {
        selected = Set(order)
        lastRange = []
    }

    public mutating func clear() {
        selected = []
        lastRange = []
    }

    /// 把一批加进 / 移出选择（比如「选这一天」）。
    public mutating func set(_ ids: some Sequence<ID>, selected on: Bool) {
        if on { selected.formUnion(ids) } else { selected.subtract(ids) }
        lastRange = []
    }

    public mutating func replace(with ids: Set<ID>) {
        selected = ids
        lastRange = []
    }

    /// 反选当前显示的内容。
    public mutating func invert() {
        let shown = Set(order)
        selected = shown.subtracting(selected).union(selected.subtracting(shown))
        lastRange = []
    }

    /// 去掉已经不存在的（比如筛选后被隐藏的内容仍然保留选择；导入后会从选择里删掉）。
    public mutating func remove(_ ids: some Sequence<ID>) {
        selected.subtract(ids)
        lastRange.subtract(ids)
    }

    // MARK: 框选

    /// 开始框选。按住 ⌘ 或 ⇧ 时在原有选择上切换，否则重新选。
    public mutating func beginBox(additive: Bool) {
        boxBase = additive ? selected : []
        boxToggles = additive
        if !additive { selected = [] }
        lastRange = []
    }

    /// 框住的内容变了。
    public mutating func updateBox(_ inside: Set<ID>) {
        guard let base = boxBase else { return }
        selected = boxToggles ? base.symmetricDifference(inside) : inside
        if let first = order.first(where: inside.contains) { anchor = first; focus = first }
    }

    public mutating func endBox() { boxBase = nil }

    public var isBoxSelecting: Bool { boxBase != nil }
}
