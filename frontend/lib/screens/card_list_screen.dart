import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/card_profile.dart';
import '../models/payment_fee_catalog.dart';
import '../providers/user_provider.dart';
import '../services/api_service.dart';
import '../services/card_profile_storage.dart';
import '../utils/payment_fee_tables.dart';

class CardListScreen extends StatefulWidget {
  const CardListScreen({super.key});

  @override
  State<CardListScreen> createState() => _CardListScreenState();
}

class _CardListScreenState extends State<CardListScreen> {
  static const _uuid = Uuid();

  final _cardStorage = CardProfileStorage();
  List<CardProfile> _cards = [];
  bool _isLoading = true;

  String? get _currentUserId => context.read<UserProvider>().currentUser?.id;

  @override
  void initState() {
    super.initState();
    _loadCards();
  }

  Future<void> _loadCards() async {
    final userId = _currentUserId;
    final api = context.read<ApiService>();
    var cards = <CardProfile>[];
    if (userId != null && userId.isNotEmpty) {
      try {
        cards = await api.getCardProfiles(userId);
        final local = await _cardStorage.loadCards(userId: userId);
        if (cards.isEmpty && local.isNotEmpty) {
          cards = await api.saveCardProfiles(userId, local);
        }
        await _cardStorage.saveCards(cards, userId: userId);
      } on ApiException {
        cards = await _cardStorage.loadCards(userId: userId);
      }
    } else {
      cards = await _cardStorage.loadCards(userId: userId);
    }
    if (!mounted) return;
    setState(() {
      _cards = cards;
      _isLoading = false;
    });
  }

  Future<void> _saveCards(List<CardProfile> cards) async {
    final userId = _currentUserId;
    final api = context.read<ApiService>();
    cards = _normalizeCardIds(cards);
    await _cardStorage.saveCards(cards, userId: userId);
    if (userId != null && userId.isNotEmpty) {
      try {
        final saved = await _saveCardProfilesWithRetry(api, userId, cards);
        cards = saved;
        await _cardStorage.saveCards(saved, userId: userId);
      } on ApiException catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.message)),
          );
        }
      }
    }
    if (!mounted) return;
    setState(() => _cards = cards);
  }

  List<CardProfile> _normalizeCardIds(List<CardProfile> cards) {
    final used = <String>{};
    return cards.map((card) {
      var id = card.id.trim();
      if (id.isEmpty || used.contains(id)) {
        id = _uuid.v4();
      }
      used.add(id);
      return card.id == id
          ? card
          : CardProfile(
              id: id,
              name: card.name,
              company: card.company,
              brand: card.brand,
              cardType: card.cardType,
              last4: card.last4,
              issuerFeeRate: card.issuerFeeRate,
              issuerFeeType: card.issuerFeeType,
              issuerFeeFixedUsd: card.issuerFeeFixedUsd,
              brandFeeRate: card.brandFeeRate,
              networkFeeWaived: card.networkFeeWaived,
              issuerFeeWaived: card.issuerFeeWaived,
              productOverrideNote: card.productOverrideNote,
              feeResearchStatus: card.feeResearchStatus,
              feeResearchSummary: card.feeResearchSummary,
              feeResearchSources: card.feeResearchSources,
              feeResearchCheckedAt: card.feeResearchCheckedAt,
              feeResearchError: card.feeResearchError,
            );
    }).toList();
  }

  Future<List<CardProfile>> _saveCardProfilesWithRetry(
    ApiService api,
    String userId,
    List<CardProfile> cards,
  ) async {
    try {
      return await api.saveCardProfiles(userId, cards);
    } on ApiException {
      await Future<void>.delayed(const Duration(milliseconds: 650));
      return api.saveCardProfiles(userId, cards);
    }
  }

  Future<void> _editCard([CardProfile? card]) async {
    final feeCatalog = await _loadPaymentFeeCatalog();
    if (!mounted) return;
    final result = await showModalBottomSheet<CardProfile>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _CardProfileSheet(
        initial: card,
        fallbackId: card?.id ?? _uuid.v4(),
        existingCards: _cards,
        feeCatalog: feeCatalog,
      ),
    );
    if (result == null) return;

    if (card == null) {
      await _addCard(result);
      return;
    }

    final next = [..._cards];
    final i = next.indexWhere((e) => e.id == result.id);
    if (i >= 0) {
      next[i] = result;
    } else {
      next.add(result);
    }
    await _saveCards(next);
  }

  Future<void> _addCard(CardProfile card) async {
    final userId = _currentUserId;
    final api = context.read<ApiService>();
    var cards = _normalizeCardIds([..._cards, card]);
    await _cardStorage.saveCards(cards, userId: userId);
    if (mounted) setState(() => _cards = cards);

    if (userId == null || userId.isEmpty) return;
    try {
      await api.createCardProfile(userId, cards.last);
      cards = await api.getCardProfiles(userId);
      await _cardStorage.saveCards(cards, userId: userId);
      if (mounted) setState(() => _cards = cards);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${e.message} 로컬에는 임시 저장했습니다.')),
      );
    }
  }

  Future<PaymentFeeCatalog> _loadPaymentFeeCatalog() async {
    try {
      return await context.read<ApiService>().getPaymentFeeCatalog();
    } catch (_) {
      return _fallbackPaymentFeeCatalog();
    }
  }

  PaymentFeeCatalog _fallbackPaymentFeeCatalog() {
    List<PaymentFeeOption> optionsFrom(Map<String, FeeRule> rules) {
      final byLabel = <String, PaymentFeeOption>{};
      for (final rule in rules.values) {
        byLabel[rule.label] = PaymentFeeOption(
          id: normalizeFeeKey(rule.label),
          label: rule.label,
          rate: rule.rate,
        );
      }
      final values = byLabel.values.toList()
        ..sort((a, b) => a.label.compareTo(b.label));
      return values;
    }

    return PaymentFeeCatalog(
      issuers: optionsFrom(defaultCardIssuerFeeRates),
      brands: optionsFrom(defaultCardBrandFeeRates),
      products: const [
        CardProductOption(
          name: '트래블로그',
          company: '하나카드',
          brand: 'Mastercard',
          cardType: 'check',
          category: 'travel_check',
        ),
        CardProductOption(
          name: 'SOL트래블',
          company: '신한카드',
          brand: 'Mastercard',
          cardType: 'credit',
          category: 'travel_credit',
        ),
        CardProductOption(
          name: '나라사랑카드',
          company: 'KB국민카드',
          brand: 'JCB',
          cardType: 'check',
          category: 'check',
        ),
      ],
    );
  }

  Future<void> _deleteCard(CardProfile card) async {
    await _saveCards(_cards.where((e) => e.id != card.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('카드목록'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _loadCards,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '카드 추가',
            onPressed: () => _editCard(),
            icon: const Icon(Icons.add_card),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _cards.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.credit_card_off_outlined,
                          size: 64,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '등록된 카드가 없습니다',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '카드를 등록해두면 영수증 입력 때 결제 카드와 해외결제 수수료를 바로 불러옵니다.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _cards.length + 1,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _CardResearchBanner(cards: _cards);
                    }
                    final card = _cards[index - 1];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.credit_card),
                        title: Text(card.displayName),
                        subtitle: _CardFeeSummary(card: card),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: '수정',
                              onPressed: () => _editCard(card),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              tooltip: '삭제',
                              onPressed: () => _deleteCard(card),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editCard(),
        icon: const Icon(Icons.add),
        label: const Text('카드 추가'),
      ),
    );
  }
}

class _CardProfileSheet extends StatefulWidget {
  final CardProfile? initial;
  final String fallbackId;
  final List<CardProfile> existingCards;
  final PaymentFeeCatalog feeCatalog;

  const _CardProfileSheet({
    required this.initial,
    required this.fallbackId,
    required this.existingCards,
    required this.feeCatalog,
  });

  @override
  State<_CardProfileSheet> createState() => _CardProfileSheetState();
}

class _CardProfileSheetState extends State<_CardProfileSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _last4Controller;
  String? _brand;
  late String _cardType;
  String? _company;
  String? _bcMemberCompany;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _last4Controller = TextEditingController(text: initial?.last4 ?? '');
    _cardType = initial?.cardType == 'check' ? 'check' : 'credit';
    final initialCompany = initial?.company.trim();
    if (initialCompany != null && initialCompany.isNotEmpty) {
      if (_isBcCompany(initialCompany)) {
        _company = 'BC카드';
        _bcMemberCompany = _bcMemberLabels.contains(initialCompany)
            ? initialCompany
            : _bcMemberLabels.first;
      } else if (_companyLabelsFor(_cardType).contains(initialCompany)) {
        _company = initialCompany;
      }
    }
    _brand = _brandLabels.contains(initial?.brand) ? initial!.brand : null;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _last4Controller.dispose();
    super.dispose();
  }

  List<CardProductOption> get _availableProducts {
    final products = widget.feeCatalog.products
        .where((product) =>
            _isSupportedCardType(product.cardType) &&
            !_isForeignWalletCompany(product.company))
        .toList()
      ..sort((a, b) {
        final byCompany = a.company.compareTo(b.company);
        if (byCompany != 0) return byCompany;
        return a.name.compareTo(b.name);
      });
    return products;
  }

  List<String> _companyLabelsFor(String cardType) {
    final labels = <String>{};
    for (final product in _availableProducts) {
      if (product.cardType != cardType) continue;
      labels.add(_isBcCompany(product.company) ? 'BC카드' : product.company);
    }
    for (final option in widget.feeCatalog.issuers) {
      if (_isForeignWalletCompany(option.label)) continue;
      labels.add(_isBcCompany(option.label) ? 'BC카드' : option.label);
    }
    final initial = widget.initial?.company;
    if (initial != null && initial.isNotEmpty) {
      labels.add(_isBcCompany(initial) ? 'BC카드' : initial);
    }
    if (labels.isEmpty) labels.add('기타');
    final sorted = labels.toList()..sort();
    sorted.remove('기타');
    sorted.remove('BC카드');
    sorted.add('BC카드');
    sorted.add('기타');
    return sorted;
  }

  List<String> get _bcMemberLabels {
    final labels = <String>{
      'BC카드',
      'IBK기업은행(BC)',
      'SC제일은행(BC)',
      'DGB대구은행(BC)',
      'BNK부산은행(BC)',
      'BNK경남은행(BC)',
      'NH농협카드(BC)',
    };
    for (final option in widget.feeCatalog.issuers) {
      if (_isBcCompany(option.label)) labels.add(option.label);
    }
    final sorted = labels.toList()..sort();
    sorted.remove('BC카드');
    return ['BC카드', ...sorted];
  }

  List<String> get _brandLabels {
    final labels = widget.feeCatalog.brands.map((e) => e.label).toList();
    final initial = widget.initial?.brand;
    if (initial != null && initial.isNotEmpty && !labels.contains(initial)) {
      labels.add(initial);
    }
    if (!labels.contains('기타')) labels.add('기타');
    return labels;
  }

  PaymentFeeOption? _findOption(List<PaymentFeeOption> options, String? label) {
    if (label == null) return null;
    for (final option in options) {
      if (option.label == label) return option;
    }
    return null;
  }

  void _changeCardType(String value) {
    final companies = _companyLabelsFor(value);
    setState(() {
      _cardType = value;
      if (_company != null && !companies.contains(_company)) _company = null;
      _bcMemberCompany = null;
      _nameController.clear();
    });
  }

  void _changeCompany(String? value) {
    setState(() {
      _company = value;
      _bcMemberCompany = value == 'BC카드' ? _bcMemberLabels.first : null;
      _nameController.clear();
    });
  }

  String? get _selectedCompany =>
      _company == 'BC카드' ? (_bcMemberCompany ?? 'BC카드') : _company;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.88,
          ),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    widget.initial == null ? '카드 추가' : '카드 수정',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                              value: 'credit',
                              icon: Icon(Icons.credit_card),
                              label: Text('신용'),
                            ),
                            ButtonSegment(
                              value: 'check',
                              icon: Icon(Icons.account_balance_wallet_outlined),
                              label: Text('체크'),
                            ),
                          ],
                          selected: {_cardType},
                          onSelectionChanged: (values) =>
                              _changeCardType(values.first),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                key: ValueKey('company_${_cardType}_$_company'),
                                initialValue: _company,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '카드사/은행',
                                  border: OutlineInputBorder(),
                                ),
                                hint: const Text('카드사/은행 선택'),
                                items: _companyLabelsFor(_cardType)
                                    .map(
                                      (label) => DropdownMenuItem(
                                        value: label,
                                        child: Text(label),
                                      ),
                                    )
                                    .toList(),
                                onChanged: _changeCompany,
                                validator: (v) =>
                                    v == null ? '카드사/은행을 선택하세요' : null,
                              ),
                            ),
                            if (_company == 'BC카드') ...[
                              const SizedBox(width: 10),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  key: ValueKey('bc_${_bcMemberCompany ?? ''}'),
                                  initialValue: _bcMemberCompany,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'BC 발급사',
                                    border: OutlineInputBorder(),
                                  ),
                                  items: _bcMemberLabels
                                      .map(
                                        (label) => DropdownMenuItem(
                                          value: label,
                                          child: Text(label),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) =>
                                      setState(() => _bcMemberCompany = v),
                                  validator: (v) =>
                                      v == null ? 'BC 발급사를 선택하세요' : null,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 12),
                        _buildProductField(),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                key: ValueKey('brand_${_brand ?? ''}'),
                                initialValue: _brand,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '브랜드',
                                  border: OutlineInputBorder(),
                                ),
                                hint: const Text('국제브랜드 선택'),
                                items: _brandLabels
                                    .map((e) => DropdownMenuItem(
                                        value: e, child: Text(e)))
                                    .toList(),
                                onChanged: (v) => setState(() => _brand = v),
                                validator: (v) =>
                                    v == null ? '국제브랜드를 선택하세요' : null,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextFormField(
                                controller: _last4Controller,
                                decoration: const InputDecoration(
                                  labelText: '끝 4자리',
                                  hintText: '선택 입력',
                                  border: OutlineInputBorder(),
                                  counterText: '',
                                ),
                                maxLength: 4,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: FilledButton(
                    onPressed: _isSaving ? null : _save,
                    child: _isSaving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('저장'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProductField() {
    return TextFormField(
      controller: _nameController,
      decoration: const InputDecoration(
        labelText: '카드 상품명',
        hintText: '예: 나라사랑카드',
        border: OutlineInputBorder(),
      ),
      validator: (v) =>
          (v == null || v.trim().isEmpty) ? '카드 상품명을 입력하세요' : null,
    );
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    if (_isSaving) return;
    setState(() => _isSaving = true);
    final last4 = _last4Controller.text.trim();
    final selectedCompany = _selectedCompany;
    final issuer = _findOption(widget.feeCatalog.issuers, selectedCompany) ??
        _findOption(widget.feeCatalog.issuers, _company);
    final brand = _findOption(widget.feeCatalog.brands, _brand);
    Navigator.pop(
      context,
      CardProfile(
        id: widget.initial?.id ?? widget.fallbackId,
        name: _nameController.text.trim(),
        company: selectedCompany ?? '',
        brand: _brand ?? '',
        cardType: _cardType,
        last4: last4.isEmpty ? null : last4,
        issuerFeeRate: issuer?.rate,
        brandFeeRate: brand?.rate,
      ),
    );
  }
}

class _CardFeeSummary extends StatelessWidget {
  final CardProfile card;

  const _CardFeeSummary({required this.card});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final lines = <String>[
      _feeLine(card),
      _researchLine(card),
      if (card.productOverrideNote != null &&
          card.productOverrideNote!.trim().isNotEmpty)
        _shorten(card.productOverrideNote!.trim()),
    ].where((e) => e.trim().isNotEmpty).toList();

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                line,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  String _feeLine(CardProfile card) {
    final brand = card.networkFeeWaived
        ? '브랜드 면제'
        : '브랜드 ${formatFeeRate(card.brandFeeRate ?? 0)}';
    final issuer = card.issuerFeeWaived
        ? '카드사 면제'
        : card.issuerFeeType == 'fixed_usd'
            ? '카드사 건당 USD ${(card.issuerFeeFixedUsd ?? 0.5).toStringAsFixed(2)}'
            : '카드사 ${formatFeeRate(card.issuerFeeRate ?? 0)}';
    return '$brand · $issuer';
  }

  String _researchLine(CardProfile card) {
    final status = switch (card.feeResearchStatus) {
      'done' => '출처 확인',
      'uncertain' => '확인 필요',
      'running' => '확인 중',
      'pending' => '확인 대기',
      'failed' => '확인 실패',
      _ => '',
    };
    if (status.isEmpty) return '';
    final sourceCount = card.feeResearchSources.length;
    return sourceCount > 0 ? '$status · 출처 $sourceCount개' : status;
  }

  String _shorten(String value) {
    const max = 58;
    if (value.length <= max) return value;
    return '${value.substring(0, max)}...';
  }
}

class _CardResearchBanner extends StatelessWidget {
  const _CardResearchBanner({required this.cards});

  final List<CardProfile> cards;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final running = cards.where((c) => c.feeResearchStatus == 'running').length;
    final pending = cards.where((c) => c.feeResearchStatus == 'pending').length;
    final done = cards.where((c) => c.feeResearchStatus == 'done').length;
    final uncertain =
        cards.where((c) => c.feeResearchStatus == 'uncertain').length;
    final failed = cards.where((c) => c.feeResearchStatus == 'failed').length;
    final label = running > 0 || pending > 0
        ? '카드 수수료 정보를 확인하는 중입니다.'
        : done > 0 || uncertain > 0
            ? '확인된 수수료를 해외결제 예상 정산액에 반영합니다.'
            : '카드를 저장하면 수수료 근거를 자동 확인합니다.';
    final detail = [
      if (done > 0) '확인 $done',
      if (uncertain > 0) '불확실 $uncertain',
      if (running > 0) '진행 $running',
      if (pending > 0) '대기 $pending',
      if (failed > 0) '실패 $failed',
    ].join(' · ');

    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.auto_awesome, color: colorScheme.primary, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '현지통화 결제액은 국제브랜드 환율로 USD 환산 후 카드사에 접수되고, '
                    '접수·매입일의 USD→KRW 환율과 국제브랜드/카드사 해외서비스 수수료를 더해 원화 청구액이 정해집니다.',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'TripScript는 이 흐름을 기준으로 정산액을 추정하고, 실제 청구액을 입력하면 그 값을 우선 반영합니다.',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      detail,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _isSupportedCardType(String value) =>
    value == 'credit' || value == 'check';

bool _isBcCompany(String value) {
  final normalized = value.toLowerCase();
  return normalized.contains('bc') ||
      value.contains('비씨') ||
      value.contains('기업은행') ||
      value.contains('SC제일') ||
      value.contains('대구은행') ||
      value.contains('부산은행') ||
      value.contains('경남은행');
}

bool _isForeignWalletCompany(String value) {
  final normalized = normalizeFeeKey(value);
  return normalized == normalizeFeeKey('트래블월렛');
}
