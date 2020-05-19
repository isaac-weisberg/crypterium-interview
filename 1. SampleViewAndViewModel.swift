public class ContactSelectorViewModel: MVVMViewModel, ContactSelectorViewModelProtocol {
    private(set) public var selected: ContactsStore.Contact? // CC: selectedIndex and selected are double copy of the same semantic, which makes it unsafe, should instead operate on index only
    private var selectedIndex: IndexPath?
    private(set) public var database: [Section] = []
    private var allContacts: [ContactsStore.Contact]? // CC: is having nil non equivalent to haveing an empty array? If so, should be composed into an enum with associated vals
    private(set) public var historyContacts: [ContactsStore.Contact] = []
    public let readOnly: Bool
    public let router: TransferToPhoneRouter
    public let operationType: WalletHistoryRecordModel.OperationType?
    private let formatter = PhoneFormatter(useRegionEmoji: false)
    private(set) public var isContactsAvailable = false
    private(set) public var isContactsNotDetermined = false
    private var searchFilter: String = ""
    private var filteredContactsDatabase: [Section] = []
    private(set) public var countryName = ""
    private lazy var customer = ContactsStore.Contact.customer // CC: singleton access, bad
    private var foldState: FoldState = .collapsed
    private var foldNotifyState: FoldState?
    private let showOwn: Bool

    private lazy var closeAction: () -> Void = { [weak self] in // CC: not entirely clear why is it needed, are you just achieving the ability to assign like `somehandler = viewModel.closeAction`
        self?.closeClosure?()
    }
    public var closeClosure: (() -> Void)?

    private lazy var contactSelected: ((_ wallet: ContactsStore.Contact, _ index: IndexPath?) -> Void) = { [weak self] wallet, index in // CC: just guard let self already and put it out of its misery
        self?.selected = wallet
        self?.selectedIndex = index
        self?.notify()
        self?.contactSelectedClosure?(wallet)
    }
    public var contactSelectedClosure: ((_ wallet: ContactsStore.Contact) -> Void)?

    public init(readOnly: Bool, operationType: WalletHistoryRecordModel.OperationType?, showOwn: Bool, router: TransferToPhoneRouter) {
        self.readOnly = readOnly
        self.router = router
        self.operationType = operationType
        self.showOwn = showOwn
        super.init()
        afterInit()
    }

    private func afterInit() {
        let authStatus = CNContactStore.authorizationStatus(for: .contacts)
        switch authStatus {
        case .authorized:
            isContactsAvailable = true
        case .notDetermined:
            isContactsNotDetermined = true
        case .denied, .restricted: // CC: missed state, the controller never handled
            break
        @unknown default:
            print("unknown authStatus: \(authStatus)")
            break
        }
        collectContacts()
        reload()
        updateHistory()
    }

    private func notify() {
        let state = foldNotifyState
        foldNotifyState = nil
        notify(with: properties(state))
    }

    private func reload() {
        if isContactsAvailable, allContacts == nil {
            collectContactsDatabase {[weak self] in
                self?.allContacts = $0
                self?.collectContacts()
            }
        }
        notify()
    }

    private func collectContacts() {
        database = []
        let own = getOwnContact()
        if !own.isEmpty {
            database.append(Section(rows: own, isCached: false))
        }
        let cached = collectCachedContacts()
        if !cached.isEmpty {
            database.append(Section(rows: cached, isCached: true))
        }
        if !(allContacts ?? []).isEmpty {
            database.append(Section(rows: allContacts ?? [], isCached: false))
        }
        updateSearch() // CC: dangerosly long chain of depending method calls
    }

    private func getOwnContact() -> [ContactsStore.Contact] {
        if showOwn, let user = customer {
            return [user]
        }
        return []
    }

    private func collectContactsDatabase(_ completion: @escaping ([ContactsStore.Contact]) -> ()) {
        ContactsStore.collect { result in // CC: singleton access, bad
            guard case .success(let contacts) = result else { return }
            completion(contacts)
        }
    }

    private func updateSearch() {
        filteredContactsDatabase = []
        let empty = searchFilter.isEmpty
        let text = searchFilter.replacingOccurrences(of: "+", with: "").uppercased()
        let textPhone = onlyDigits(text)
        filteredContactsDatabase = []
        var all: [ContactsStore.Contact] = []
        database.forEach { // CC: logic of formatting input near the logic filtering the results
            var section = $0
            if empty {
                section.rows = section.rows.filter({ !all.contains($0) })
            } else {
                section.rows = section.rows.filter({ $0.name.uppercased().contains(text) || onlyDigits($0.phone).contains(textPhone) })
            }
            all += section.rows
            if !section.rows.isEmpty {
                filteredContactsDatabase.append(section)
            }
        }
        notify()
    }

    private func phoneEditingChanged(_ textString: String) {
        let prev = searchFilter
        countryName = ""
        searchFilter = textString
        defer {
            if searchFilter != prev {
                let digits = onlyDigits(searchFilter)
                if !digits.isEmpty {
                    selected = ContactsStore.Contact(with: countryName, phone: searchFilter, avatar: nil)
                } else {
                    selected = nil
                }
                selectedIndex = nil
                updateSearch()
            }
        }
        var phoneText = textString // CC: number formatting logic can be moved into a separate stateless service and injected
        let containsLetters = phoneText.rangeOfCharacter(from: .letters) != nil
        if !phoneText.contains("+") && !phoneText.isEmpty && !containsLetters {
            phoneText = "+" + phoneText
        }

        let phoneKit = PhoneNumberKit()
        guard let phoneNumber = try? phoneKit.parse(phoneText) else {
            searchFilter = phoneText
            return
        }
        var phoneNumberFormatted = phoneKit.format(phoneNumber, toType: .international, withPrefix: false)
        if phoneNumber.numberString.replacingOccurrences(of: " ", with: "") != phoneNumberFormatted.replacingOccurrences(of: " ", with: "") {
            phoneNumberFormatted = "+\(phoneNumber.countryCode) \(phoneNumberFormatted)"
        }
        searchFilter = phoneNumberFormatted

        let current = Locale(identifier: "en_US") // CC: can be moved into a separate service
        guard let regionCode = phoneNumber.regionID,
            let cn = current.localizedString(forRegionCode: regionCode) else {
                return
        }
        countryName = cn
    }

    private func sections() -> [PhoneSelectorTableView.Section] {
        var sections: [PhoneSelectorTableView.Section] = filteredContactsDatabase.enumerated().map { section(for: $0.element, $0.offset) }
        if filteredContactsDatabase.isEmpty {
            sections.append(.notFound(
                detailed: isContactsAvailable,
                contact: ContactView.ViewProperties( // CC: it's a very special, nearly static case of not found, why is being fed so much information that it probably doesn't use considering that everything is nil
                    name: searchFilter,
                    phone: countryName,
                    icon: nil,
                    isOwn: false,
                    status: nil,
                    action: {[weak self] in
                        guard let self = self else { return }
                        let digits = self.onlyDigits(self.searchFilter)
                        guard !digits.isEmpty else { return }
                        let contact = ContactsStore.Contact(with: self.countryName, phone: self.searchFilter, avatar: nil)
                        self.foldNotifyState = self.foldState == .collapsed ? .expanded : .collapsed
                        self.contactSelected(contact, nil)
                    }
                )
            ))
        }
        if !isContactsAvailable {
            sections.append(.access(PhoneAccessCell.ViewProperties.default {[weak self] in
                self?.accessRequest()
            }))
        }
        return sections
    }

    private func section(for contacts: Section, _ s: Int) -> PhoneSelectorTableView.Section {
        let array = contacts.rows.enumerated().map { row(for: $0.element, isCached: contacts.isCached, index: IndexPath(row: $0.offset, section: s)) }
        return .contacts(array)
    }

    private func row(for contact: ContactsStore.Contact, isCached: Bool, index: IndexPath) -> ContactView.ViewProperties {
        return ContactView.ViewProperties(
            name: contact.name,
            phone: contact.phone,
            icon: contact.avatar,
            isOwn: contact == customer,
            status: readOnly ? nil : (foldState == .collapsed && index == selectedIndex) ? .collapsed : (isCached ? .recent : nil),
            action: {[weak self] in
                self?.foldNotifyState = self?.foldState == .collapsed ? .expanded : .collapsed
                self?.contactSelected(contact, index)
            }
        )
    }

    private func properties(_ foldNotifyState: FoldState?) -> PhoneSelectorTableView.ViewProperties { // CC: view model is aware of a structural definition of the view's state machine, which violates the unidirectional structural awareness. What if we would like to build a new view but reusing the viewmodel, it's business logic and interface? View can and should depend on the interface and abstractions of a viewmodel, but viewmodel should never be aware of its clients AKA the view.
        return PhoneSelectorTableView.ViewProperties(
            selected: selectedIndex,
            sections: sections(),
            searchText: nil,
            onTextChanged: {[weak self] in self?.phoneEditingChanged($0) },
            state: foldState,
            notifyState: foldNotifyState,
            updateState: {[weak self] in
                self?.foldState = $0
                self?.notify()
            },
            style: readOnly ? .fixed : .usual
        )

    }

    private func accessRequest() {
        CNContactStore().requestAccess(for: .contacts) { [weak self] granted, error in
            guard let `self` = self else { return }
            guard granted else {
                guard !self.isContactsNotDetermined else {
                    self.isContactsNotDetermined = false
                    return
                }
                DispatchQueue.main.async {
                    self.router.showPhoneAccessAlert()
                }
                return
            }
            self.isContactsAvailable = true
            self.reload()
        }
    }

    private func comparePhones(_ phone1: String, _ phone2: String) -> Bool { // CC: has nothing to do with viewmodel, should be moved to separate extension
        let lhs = onlyDigits(phone1)
        let rhs = onlyDigits(phone2)
        return lhs == rhs
    }

    private func onlyDigits(_ str: String) -> String { // CC: has nothing to do with viewmodel, should be moved to a separate static extension
        str.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
    }

    private func updateHistory() {
        guard let operation = operationType else { return }
        CRPTHistoryAPI.getWalletHistoryUsingGETWithRequestBuilder(
            currencyFilter: nil,
            extraFilter: nil,
            offset: 0,
            size: 5,
            typeFilter: [operation.rawValue]
        ).simpleExecute { [weak self] result in // CC: no mechanism to enforce sequentality of handler calls
            guard let it = self, case .success(let model) = result else { return }
            let list = model.history.list.compactMap { it.contact(from: $0.walletHistoryRecordTransferPhone) }
            it.historyContacts = list.reduce([], { $0 + ($0.contains($1) ? [] : [$1]) })
            it.reload()
        }
    }

    private func contact(from history: WalletHistoryRecordTransferPhone?) -> ContactsStore.Contact? {
        guard let phone = history?.toPhone else { return nil }
        if let con = allContacts?.first(where: { comparePhones($0.phone, phone) }) {
            return con
        }
        return ContactsStore.Contact(with: history?.toName ?? "", phone: phone, avatar: nil)
    }

    public struct Section {
        public var rows: [ContactsStore.Contact] // CC: exposes a model from the model layer to the view
        public var isCached: Bool

        public init(rows: [ContactsStore.Contact], isCached: Bool) {
            self.rows = rows
            self.isCached = isCached
        }
    }

}

public class SelectedContactViewModel: MVVMViewModel, ContactSelectorViewModelProtocol { // CC: How is this protocol both implemented for a list of contacts and  a "selected contact". My imagination tells me that this view model can be used with the whole controller with that table view to show only one, single contact as a detail presentation of a contact from the list. This should not be like this. Instead, the cell that is the view that is able to present using `ContactView.ViewProperties` should be a separate independent view that is used both in the list and in the detail presentation. Leaving the table where there is no table is a dirty hack and an obstacle for modification.

    public let contact: ContactsStore.Contact
    public var selected: ContactsStore.Contact? { contact }

    public init(_ contact: ContactsStore.Contact) {
        self.contact = contact
        super.init()
        notify()
    }

    private func notify() {
        notify(with: PhoneSelectorTableView.ViewProperties(
            selected: IndexPath(row: 0, section: 0),
            sections: [.contacts([ContactView.ViewProperties(
                name: contact.name,
                phone: contact.phone,
                icon: contact.avatar,
                isOwn: contact.isCustomer,
                status: nil,
                action: nil
            )])],
            searchText: nil,
            onTextChanged: {_ in},
            state: .collapsed,
            notifyState: nil,
            updateState: {_ in},
            style: .fixed
        ))
    }

}

public class PhoneSelectorTableView: UIView, MVVMViewProtocol, FoldableView { // CC: bad naming, it's not a table view

    public struct ViewProperties {
        public let selected: IndexPath?
        public let sections: [Section]
        public let searchText: String?
        public let onTextChanged: (String) -> () // CC: view properties updates nearly on a dime when searching, selecting, folding - but onTextChanged always stays the same. It can be injected during the beginning of the MVVM stack lifecycle. Same thing with updateState
        public let state: FoldState
        public let notifyState: FoldState?
        public let updateState: (FoldState) -> ()
        public let style: Style

        public enum Style {
            case usual
            case fixed
        }

        public init(selected: IndexPath?, sections: [Section], searchText: String?, onTextChanged: @escaping (String) -> (), state: FoldState, notifyState: FoldState?, updateState: @escaping (FoldState) -> (), style: Style) {
            self.selected = selected
            self.sections = sections
            self.searchText = searchText
            self.onTextChanged = onTextChanged
            self.state = state
            self.notifyState = notifyState
            self.updateState = updateState
            self.style = style
        }

    }

    @IBOutlet private var contentView: UIView!
    @IBOutlet private weak var tableView: UITableView! // CC: no need for them to be weak
    @IBOutlet private weak var phoneTextFieldOutlet: CRPTTextField! // CC: text field can have its own viewmodel that features the business logic related to text modification, formatting, and propagating its value to someone who might need it. Relatedly, the table view viewmodel should have its own view model that features all the stuff related to the presentation of the list, but not the input filtering logic

    private let selectorCellID = "PhoneSelectorCell"
    private let accessCellID = "PhoneAccessCell"
    private let notFoundCellID = "PhoneNotFoundCell"

    public var needChangeFoldState: (FoldState) -> () = {_ in} // CC: can't even imagine what does it do here? View model will listen to this at some point?
    private var properties = ViewProperties(selected: nil, sections: [], searchText: nil, onTextChanged: {_ in}, state: .collapsed, notifyState: nil, updateState: {_ in}, style: .usual)
    private var selected: IndexPath? { properties.selected }
    private var tappedRow: IndexPath?
    private var foldState: FoldState { properties.state }
    private let selectedIcon = Asset.Images.walletSelected.image.tinted(with: Color.green)
    private let arrow = Asset.Images.crossDown.image.tinted(with: Color.darkterium50)
    public var isEnabled = true
    public var showKeyboardOnExpand: Bool { true }
    private var showSearch: Bool { tappedRow == nil || foldState == .expanded }

    public func update(with properties: ViewProperties) {
        let prevCollapsed = foldState
        self.properties = properties
        switch properties.style {
        case .usual:
            tableView.isUserInteractionEnabled = true
        case .fixed:
            phoneTextFieldOutlet.isHidden = true
            tableView.isUserInteractionEnabled = false
        }
        if prevCollapsed != foldState {
            switch foldState {
            case .collapsed: configureCollapse()
            case .expanded:  configureExpand()
            }
        } else {
            tableView.reloadData()
        }
        if let state = properties.notifyState {
            needChangeFoldState(state)
        }
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        afterInit()
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        afterInit()
    }

    public init() {
        super.init(frame: .zero)
        afterInit()
    }

    private func afterInit() {
        Bundle(for: PhoneSelectorTableView.self).loadNibNamed("PhoneSelectorView", owner: self, options: nil)
        addSubviewAndPinAllEdges(contentView)
        phoneTextFieldOutlet.autocorrectionType = .no
        setupUI()
    }

    private func setupUI() {
        let paddingView = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: phoneTextFieldOutlet.frame.size.height))
        paddingView.isUserInteractionEnabled = false
        phoneTextFieldOutlet.leftView = paddingView
        phoneTextFieldOutlet.leftViewMode = .always

        phoneTextFieldOutlet.backgroundColor = Color.darkterium10
        phoneTextFieldOutlet.title = L10n.Localizable.fProfileEditPhoneHint
        phoneTextFieldOutlet.floatingLabelFont = Font.SFProText.regular.font(size: 12)
        phoneTextFieldOutlet.textColor = Color.black
        phoneTextFieldOutlet.font = Font.SFProText.regular.font(size: 16)
        phoneTextFieldOutlet.borderStyle = .none

        tableView.tableFooterView = UIView(frame: CGRect.zero)
        tableView.register(UINib(nibName: "PhoneSelectorCell", bundle: CRPTBundle), forCellReuseIdentifier: selectorCellID)
        tableView.register(UINib(nibName: "PhoneAccessCell", bundle: CRPTBundle), forCellReuseIdentifier: accessCellID)
        tableView.register(UINib(nibName: "PhoneNotFoundCell", bundle: CRPTBundle), forCellReuseIdentifier: notFoundCellID)
        tableView.estimatedRowHeight = CRPTItemView.defaultHeight
        tableView.rowHeight = UITableView.automaticDimension
    }

    public func changeFoldState(_ state: FoldState) -> CGFloat? {
        switch state {
        case .expanded:   return expand()
        case .collapsed:  return collapse()
        }
    }

    private func collapse() -> CGFloat? {
        guard foldState == .expanded else { return CRPTItemView.defaultHeight }
        properties.updateState(.collapsed)
        return CRPTItemView.defaultHeight
    }

    private func configureCollapse() {
        phoneTextFieldOutlet.isHidden = selected != nil || properties.style == .fixed
        let index = tappedRow ?? selected ?? IndexPath(row: 0, section: 0)
        frame.size.height = CRPTItemView.defaultHeight
        tableView.frame.size.height = CRPTItemView.defaultHeight
        tableView.scrollToRow(at: index, at: .top, animated: false)
        tableView.isScrollEnabled = false
        (tableView.cellForRow(at: index) as? PhoneSelectorCell)?.selectAnimation()
        phoneTextFieldOutlet.resignFirstResponder()
    }

    public func showKeyboardForExpandIfNeeded() {
        phoneTextFieldOutlet.becomeFirstResponder()
    }

    private func expand() -> CGFloat? {
        let result = properties.sections.reduce(0, {sum, e in sum + height(for: e) * CGFloat(e.rowCount) }) + CRPTItemView.defaultHeight
        guard foldState == .collapsed else { return result }
        properties.updateState(.expanded)
        return result
    }

    private func configureExpand() {
        phoneTextFieldOutlet.isHidden = false
        tableView.isScrollEnabled = true
        let index = selected ?? IndexPath(row: 0, section: 0)
        tableView.scrollToRow(at: index, at: .top, animated: false)
        (tableView.cellForRow(at: index) as? PhoneSelectorCell)?.selectAnimation()
//        defer { phoneTextFieldOutlet.becomeFirstResponder() }
    }

    @IBAction func phoneEditingChanged(_ sender: Any) {
        properties.onTextChanged(phoneTextFieldOutlet.text ?? "")
    }

    @IBAction func searchTapped(_ sender: Any) {
        needChangeFoldState(.expanded)
    }

}

extension PhoneSelectorTableView: UITableViewDataSource, UITableViewDelegate {

    fileprivate func height(for section: Section) -> CGFloat {
        switch section { // CC: hardcoded heights, terrible approach
        case .notFound(let detailed, _):
            if detailed {
                return 340
            } else {
                return CRPTItemView.defaultHeight
            }
        case .access:
            return 210
        case .contacts:
            return CRPTItemView.defaultHeight
        }
    }

    fileprivate func numberOfCells() -> Int {
        return properties.sections.reduce(0) { $0 + $1.rowCount }
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return properties.sections[section].rowCount
    }

    public func numberOfSections(in tableView: UITableView) -> Int {
        return properties.sections.count
    }

    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return height(for: properties.sections[indexPath.section])
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        var cell = UITableViewCell() // CC: unnecessary cell creation
        let section = properties.sections[indexPath.section]
        switch section {
        case .notFound(let detailed, let props):
            if detailed {
                guard let notFoundCell = tableView.dequeueReusableCell(withIdentifier: notFoundCellID) as? PhoneNotFoundCell else { return UITableViewCell() }
                notFoundCell.update(with: PhoneNotFoundCell.ViewProperties.with(props))
                cell = notFoundCell
            } else {
                guard let notFoundCell = tableView.dequeueReusableCell(withIdentifier: selectorCellID) as? PhoneSelectorCell else { return UITableViewCell() }
                notFoundCell.configure(with: props, isLast: true)
                cell = notFoundCell
            }
        case .access(let props):
            guard let accessCell = tableView.dequeueReusableCell(withIdentifier: accessCellID) as? PhoneAccessCell else { return UITableViewCell() }
            accessCell.update(with: props)
            cell = accessCell
        case .contacts(let rows):
            guard let selectorCell = tableView.dequeueReusableCell(withIdentifier: selectorCellID) as? PhoneSelectorCell else { return UITableViewCell() }

            let props = rows[indexPath.row]
            let isLast = indexPath.row >= rows.count - 1 && foldState == .expanded

            selectorCell.configure(with: props, isLast: isLast)
            cell = selectorCell
        }
        return cell
    }

    public enum Section {
        case notFound(detailed: Bool, contact: ContactView.ViewProperties), access(PhoneAccessCell.ViewProperties), contacts([ContactView.ViewProperties])
        public var rowCount: Int {
            switch self {
            case .contacts(let rows): return rows.count
            default: return 1
            }
        }
    }

}

extension PhoneSelectorTableView: UITextFieldDelegate {

    public func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        self.needChangeFoldState(.expanded)
        return true
    }

}
