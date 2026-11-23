import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/card_profile.dart';
import '../models/receipt.dart';
import '../models/trip.dart';
import '../providers/trip_provider.dart';
import '../providers/user_provider.dart';
import '../services/api_service.dart';
import '../services/card_profile_storage.dart';
import '../services/ocr_service.dart';
import '../utils/exchange_rates.dart';
import '../utils/format_money.dart';
import '../utils/payment_estimator.dart';
import '../utils/payment_fee_tables.dart';

class AddReceiptScreen extends StatefulWidget {
  final String tripId;
  final Receipt? receipt;

  const AddReceiptScreen({
    super.key,
    required this.tripId,
    this.receipt,
  });

  @override
  State<AddReceiptScreen> createState() => _AddReceiptScreenState();
}

class _AddReceiptScreenState extends State<AddReceiptScreen> {
  final _formKey = GlobalKey<FormState>();
  final _storeController = TextEditingController();
  final _amountController = TextEditingController();
  final _cardIssuerController = TextEditingController();
  final _bankNameController = TextEditingController();
  final _cardBrandController = TextEditingController();
  final _cardLast4Controller = TextEditingController();
  final _cashExchangeFeeController = TextEditingController();
  final _paymentCorrectionController = TextEditingController();
  final _actualKrwController = TextEditingController();
  final _cardStorage = CardProfileStorage();
  String _category = '식비';
  String? _paidBy;
  String? _imagePath;
  Map<String, dynamic>? _recognition;
  double? _recognitionConfidence;
  List<String> _recognitionWarnings = const [];
  DateTime _date = DateTime.now();
  bool _isOcrLoading = false;
  bool _isImageUploading = false;
  bool _isAutoSaving = false;
  String? _ocrStatusMessage;
  bool _didPromptInitialDate = false;
  bool _didUserChooseDate = false;
  bool _didUserChooseCurrency = false;
  String _currencyCode = 'KRW';
  String _paymentMethod = paymentMethodCard;
  List<CardProfile> _cards = [];
  String? _selectedCardId;
  PaymentEstimate? _serverPaymentEstimate;
  Timer? _estimateDebounce;
  int _estimateRequestSerial = 0;
  bool _isEstimateRefreshing = false;

  /// 예상 정산 패널: 접으면 헤더만, 펼치면 세부 계산 노출
  bool _paymentEstimateExpanded = false;

  /// OCR·직접 입력 품목 (정산 화면 등에서 사용)
  late List<ReceiptItem> _items;

  /// 품목 추가/수정 초안 (다이얼로그 미사용 — dispose 타이밍 이슈 방지)
  final _itemDraftNameController = TextEditingController();
  final _itemDraftTotalController = TextEditingController();
  final _itemDraftQtyController = TextEditingController(text: '1');
  final _itemDraftPriceController = TextEditingController();

  /// 참가자별 정산 수량 (+- 스테퍼, 0이면 저장 시 맵에서 생략)
  final Map<String, double> _personQtyDraftValues = {};
  int? _editingItemIndex;
  bool _showAdvancedSplit = false;

  /// 신규 영수증에서 품목 추가로 자동 저장된 뒤 `updateReceipt`에 쓰는 id
  String? _persistedReceiptId;

  /// 품목 불러오기 등으로 컨트롤러를 일괄 설정할 때 단가 자동계산 리스너와 충돌 방지
  bool _suppressUnitFromTotal = false;
  bool _suppressTotalFromUnit = false;

  final _categories = [
    '식비',
    '카페',
    '교통',
    '숙박',
    '관광',
    '쇼핑',
    '마트',
    '문화',
    '의료',
    '통신',
    '기타',
  ];
  final _picker = ImagePicker();
  final _ocr = OcrService();

  static const _fieldPadding =
      EdgeInsets.symmetric(horizontal: 12, vertical: 16);

  /// 품목 초안(품목명·총가격·수량·단가) — 숫자가 칸 안에 들어가도록 작은 글꼴
  static const EdgeInsets _itemDraftContentPadding =
      EdgeInsets.symmetric(horizontal: 10, vertical: 10);

  TextStyle get _itemDraftValueStyle {
    final t = Theme.of(context).textTheme;
    return (t.bodyLarge ?? const TextStyle())
        .copyWith(fontSize: 13, height: 1.2);
  }

  InputDecoration _itemDraftInputDecoration({
    required String labelText,
    String? hintText,
    String? suffixText,
  }) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      suffixText: suffixText,
      border: const OutlineInputBorder(),
      isDense: true,
      contentPadding: _itemDraftContentPadding,
      labelStyle: (t.labelLarge ?? const TextStyle()).copyWith(
        fontSize: 11.5,
        color: cs.onSurfaceVariant,
      ),
      floatingLabelStyle: (t.labelLarge ?? const TextStyle()).copyWith(
        fontSize: 11.5,
        height: 1,
      ),
      hintStyle: (t.bodySmall ?? const TextStyle()).copyWith(
        fontSize: 12,
        color: cs.onSurfaceVariant,
      ),
      suffixStyle: (t.labelSmall ?? const TextStyle()).copyWith(
        fontSize: 11,
        color: cs.onSurfaceVariant,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    final currentUserName =
        context.read<UserProvider>().currentUser?.displayName;
    if (widget.receipt != null) {
      final r = widget.receipt!;
      _storeController.text = r.storeName;
      _amountController.text = _formatCurrencyInput(r.amount, r.currencyCode);
      _category = r.category;
      _paidBy = r.paidBy;
      _imagePath = r.imagePath;
      _recognition = r.recognition;
      _recognitionConfidence = r.confidence;
      _recognitionWarnings = r.warnings;
      _date = r.date;
      _currencyCode = r.currencyCode;
      _cardIssuerController.text = r.cardIssuer ?? '';
      _bankNameController.text = r.bankName ?? '';
      _cardBrandController.text = r.cardBrand ?? '';
      _cardLast4Controller.text = r.cardLast4 ?? '';
      _paymentMethod = r.paymentMethod == paymentMethodCash
          ? paymentMethodCash
          : paymentMethodCard;
      _cashExchangeFeeController.text =
          r.cashKrwPerUnit == null ? '' : _formatNumberInput(r.cashKrwPerUnit!);
      _paymentCorrectionController.text =
          _formatRatePercentInput(r.paymentCorrectionRate);
      _actualKrwController.text = r.actualKrwAmount == null
          ? ''
          : r.actualKrwAmount!.toStringAsFixed(0);
      _items = r.items
          .map(
            (e) => e.copyWith(
              quantityByPerson: Map<String, double>.from(e.quantityByPerson),
            ),
          )
          .toList();
    } else {
      _items = [];
      _paidBy = currentUserName;
    }
    _loadCardProfiles();
    _amountController.addListener(_onReceiptAmountChanged);
    _cashExchangeFeeController.addListener(_scheduleServerPaymentEstimate);
    _paymentCorrectionController.addListener(_scheduleServerPaymentEstimate);
    _actualKrwController.addListener(_scheduleServerPaymentEstimate);
    _itemDraftTotalController.addListener(_syncUnitFromTotalAndQty);
    _itemDraftQtyController.addListener(_onItemDraftQtyChanged);
    _itemDraftPriceController.addListener(_onItemDraftUnitChanged);
    _scheduleServerPaymentEstimate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didPromptInitialDate || widget.receipt != null) return;
    _didPromptInitialDate = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final trip = context.read<TripProvider>().getTrip(widget.tripId);
      if (trip == null || !mounted) return;
      final clamped = _clampDateToTrip(_date, trip);
      if (clamped != _date) {
        setState(() => _date = clamped);
      }
      _startInitialReceiptFlow(trip);
    });
  }

  Future<void> _loadCardProfiles() async {
    final user = context.read<UserProvider>().currentUser;
    final trip = context.read<TripProvider>().getTrip(widget.tripId);
    final paidBy = _paidBy;
    var cards = <CardProfile>[];

    if (user != null && trip != null && paidBy != null && paidBy.isNotEmpty) {
      final api = context.read<ApiService>();
      final isHost = user.matchesParticipantName(trip.hostName);
      final isOwnPayer = user.matchesParticipantName(paidBy);
      try {
        if (isHost || isOwnPayer) {
          cards = await api.getTripParticipantCardProfiles(
            userId: user.id,
            tripId: trip.id,
            participantName: paidBy,
          );
        }
        if (isOwnPayer) {
          final local = await _cardStorage.loadCards(userId: user.id);
          if (cards.isEmpty && local.isNotEmpty) {
            cards = await api.saveCardProfiles(user.id, local);
          }
          await _cardStorage.saveCards(cards, userId: user.id);
        }
      } on ApiException {
        if (isOwnPayer) {
          cards = await _cardStorage.loadCards(userId: user.id);
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _cards = cards;
      _selectedCardId = _matchCardProfileId(cards);
    });
  }

  void _setPaidBy(String? paidBy) {
    setState(() {
      _paidBy = paidBy;
      _selectedCardId = null;
      _cardIssuerController.clear();
      _bankNameController.clear();
      _cardBrandController.clear();
      _cardLast4Controller.clear();
      _cards = [];
    });
    _loadCardProfiles();
  }

  Future<void> _startInitialReceiptFlow(dynamic trip) async {
    final picked = await _pickImage(
      recognizeAfterUpload: true,
      waitForRecognition: false,
    );
    if (!mounted) return;
    await _pickReceiptDate(trip);
    if (!mounted) return;
    if (picked) {
      await _showInitialPaymentSetupSheet(trip);
    }
  }

  Future<void> _showInitialPaymentSetupSheet(dynamic trip) async {
    final user = context.read<UserProvider>().currentUser;
    final currentUserName = user?.displayName;
    final canChoosePayer =
        user != null && user.matchesParticipantName(trip.hostName);
    final payerSet = <String>{
      if (_paidBy != null && _paidBy!.isNotEmpty) _paidBy!,
      if (canChoosePayer)
        ...trip.participants.cast<String>()
      else if (currentUserName != null && currentUserName.isNotEmpty)
        currentUserName,
    };
    final payerItems = payerSet.toList();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> refreshCards() async {
            await _loadCardProfiles();
            if (mounted) setSheetState(() {});
          }

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.viewInsetsOf(ctx).bottom + 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '결제 정보',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _isOcrLoading
                          ? '영수증을 인식하는 동안 결제 정보를 먼저 입력하세요.'
                          : '인식 결과가 도착하면 입력폼에 자동 반영됩니다.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (payerItems.isNotEmpty) ...[
                      DropdownButtonFormField<String>(
                        initialValue: payerItems.contains(_paidBy)
                            ? _paidBy
                            : payerItems.first,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '결제자',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: _fieldPadding,
                        ),
                        items: payerItems
                            .map(
                              (name) => DropdownMenuItem(
                                value: name,
                                child: Text(name),
                              ),
                            )
                            .toList(),
                        onChanged: canChoosePayer
                            ? (value) {
                                setState(() {
                                  _paidBy = value;
                                  _selectedCardId = null;
                                  _cardIssuerController.clear();
                                  _bankNameController.clear();
                                  _cardBrandController.clear();
                                  _cardLast4Controller.clear();
                                });
                                setSheetState(() {});
                                unawaited(refreshCards());
                              }
                            : null,
                      ),
                      const SizedBox(height: 12),
                    ],
                    DropdownButtonFormField<String>(
                      initialValue: _currencyCode,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '통화',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: _fieldPadding,
                      ),
                      items: supportedCurrencyCodes
                          .map(
                            (c) => DropdownMenuItem(
                              value: c,
                              child: Text(_currencyOptionLabel(c)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        _setCurrency(value ?? 'KRW');
                        setSheetState(() {});
                      },
                    ),
                    const SizedBox(height: 12),
                    if (_canEditCurrentPaymentDetails) ...[
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: paymentMethodCard,
                            icon: Icon(Icons.credit_card),
                            label: Text('카드'),
                          ),
                          ButtonSegment(
                            value: paymentMethodCash,
                            icon: Icon(Icons.payments_outlined),
                            label: Text('현금'),
                          ),
                        ],
                        selected: {_paymentMethod},
                        onSelectionChanged: (values) {
                          setState(() {
                            _paymentMethod = values.first;
                            if (_paymentMethod == paymentMethodCash) {
                              _selectedCardId = null;
                              _cardIssuerController.clear();
                              _bankNameController.clear();
                              _cardBrandController.clear();
                              _cardLast4Controller.clear();
                              _actualKrwController.clear();
                            } else {
                              _cashExchangeFeeController.clear();
                            }
                          });
                          setSheetState(() {});
                          _scheduleServerPaymentEstimate();
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_paymentMethod == paymentMethodCard)
                      DropdownButtonFormField<String>(
                        key: ValueKey(
                          'initial_card_${_selectedCardId ?? 'none'}_${_cards.length}',
                        ),
                        initialValue: _selectedCardId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '결제 카드',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: _fieldPadding,
                        ),
                        items: [
                          const DropdownMenuItem<String>(
                            value: null,
                            child: Text('선택 안 함'),
                          ),
                          ..._cards.map(
                            (card) => DropdownMenuItem<String>(
                              value: card.id,
                              child: Text(
                                card.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          _applyCardProfile(value);
                          setSheetState(() {});
                        },
                      )
                    else
                      TextField(
                        controller: _cashExchangeFeeController,
                        decoration: InputDecoration(
                          labelText: '환전 적용 환율',
                          hintText: _cashRateHintText,
                          suffixText: '원 / $_currencyCode',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          contentPadding: _fieldPadding,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) {
                          setState(() {});
                          setSheetState(() {});
                        },
                      ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('계속 입력하기'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String? _matchCardProfileId(List<CardProfile> cards) {
    for (final card in cards) {
      if (card.company == _cardIssuerController.text.trim() &&
          card.name == _bankNameController.text.trim() &&
          card.brand == _cardBrandController.text.trim() &&
          (card.last4 ?? '') == _cardLast4Controller.text.trim()) {
        return card.id;
      }
    }
    return null;
  }

  CardProfile? get _selectedCardProfile {
    final selectedId = _selectedCardId;
    if (selectedId == null) return null;
    for (final card in _cards) {
      if (card.id == selectedId) return card;
    }
    return null;
  }

  void _applyCardProfile(String? cardId) {
    setState(() {
      _selectedCardId = cardId;
      final card = _cards.cast<CardProfile?>().firstWhere(
            (e) => e?.id == cardId,
            orElse: () => null,
          );
      _cardIssuerController.text = card?.company ?? '';
      _bankNameController.text = card?.name ?? '';
      _cardBrandController.text = card?.brand ?? '';
      _cardLast4Controller.text = card?.last4 ?? '';
    });
    _scheduleServerPaymentEstimate();
  }

  void _onItemDraftQtyChanged() {
    _syncTotalFromUnitAndQty();
    if (!_showAdvancedSplit) {
      _assignEvenSplitToSelectedTargets();
    }
    if (mounted) setState(() {});
  }

  void _onItemDraftUnitChanged() {
    _syncTotalFromUnitAndQty();
    if (mounted) setState(() {});
  }

  void _onReceiptAmountChanged() {
    _scheduleServerPaymentEstimate();
    if (mounted) setState(() {});
  }

  void _applyRecognizedReceipt(Receipt recognized) {
    final trip = context.read<TripProvider>().getTrip(widget.tripId);
    final nextCurrency =
        supportedCurrencyCodes.contains(recognized.currencyCode)
            ? recognized.currencyCode
            : _currencyCode;
    final nextDate = trip == null
        ? recognized.date
        : _clampDateToTrip(recognized.date, trip);
    final nextCategory = _categories.contains(recognized.category)
        ? recognized.category
        : _category;
    final amountCurrency =
        _didUserChooseCurrency ? _currencyCode : nextCurrency;
    final nextItems = recognized.items
        .where((item) => item.name.trim().isNotEmpty && item.lineTotal >= 0)
        .map(
          (item) => item.copyWith(
            quantityByPerson: const {},
          ),
        )
        .toList();

    setState(() {
      final nextPm = recognized.paymentMethod == paymentMethodCash
          ? paymentMethodCash
          : paymentMethodCard;
      if (_paymentMethod != nextPm) {
        if (nextPm == paymentMethodCash) {
          _selectedCardId = null;
          _cardIssuerController.clear();
          _bankNameController.clear();
          _cardBrandController.clear();
          _cardLast4Controller.clear();
          _actualKrwController.clear();
        } else {
          _cashExchangeFeeController.clear();
        }
      }
      _paymentMethod = nextPm;
      if (recognized.storeName.trim().isNotEmpty) {
        _storeController.text = recognized.storeName.trim();
      }
      if (recognized.amount > 0) {
        _amountController.text =
            _formatCurrencyInput(recognized.amount, amountCurrency);
      }
      if (!_didUserChooseCurrency) {
        _currencyCode = nextCurrency;
      }
      if (!_didUserChooseDate) {
        _date = nextDate;
      }
      _category = nextCategory;
      if (nextItems.isNotEmpty) {
        _items = nextItems;
      }
      _recognition = recognized.recognition;
      _recognitionConfidence = recognized.confidence;
      _recognitionWarnings = recognized.warnings;
      _ocrStatusMessage = '영수증 인식 결과를 입력폼에 반영했습니다.';
    });
    _scheduleServerPaymentEstimate();
  }

  Future<void> _recognizeCurrentReceiptImage({bool showSnackBar = true}) async {
    final imagePath = _imagePath;
    if (imagePath == null || imagePath.isEmpty) return;
    if (!imagePath.startsWith('http://') &&
        !imagePath.startsWith('https://') &&
        !imagePath.startsWith('/api/v1/media/')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('사진 업로드가 끝난 뒤 인식할 수 있습니다.')),
      );
      return;
    }

    setState(() {
      _isOcrLoading = true;
      _ocrStatusMessage = '영수증을 인식하고 있습니다.';
    });
    try {
      final recognized = await context.read<ApiService>().recognizeReceiptImage(
            imagePath,
            currencyCode: _currencyCode,
          );
      if (!mounted) return;
      _applyRecognizedReceipt(recognized);
      await _autoSaveReceiptDraft('인식 결과');
      if (!mounted) return;
      if (showSnackBar) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('영수증 인식 결과를 반영했습니다.')),
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = _friendlyRecognitionError(e.message);
      setState(() => _ocrStatusMessage = message);
      if (showSnackBar) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isOcrLoading = false);
      }
    }
  }

  String _friendlyRecognitionError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('gemini') ||
        lower.contains('quota') ||
        lower.contains('429') ||
        lower.contains('한도')) {
      return raw.length > 80 ? 'Gemini 무료 인식 한도에 걸렸습니다. 잠시 뒤 다시 시도해 주세요.' : raw;
    }
    if (lower.contains('timeout') ||
        lower.contains('timed out') ||
        lower.contains('receive timeout')) {
      return '인식 시간이 길어졌습니다. 잠시 뒤 다시 인식해 주세요.';
    }
    if (lower.contains('network') ||
        lower.contains('socket') ||
        lower.contains('connection') ||
        lower.contains('ngrok')) {
      return '서버 연결이 불안정합니다. 네트워크와 백엔드 상태를 확인해 주세요.';
    }
    if (lower.contains('parse') ||
        lower.contains('json') ||
        lower.contains('candidate')) {
      return '영수증 내용을 구조화하지 못했습니다. 사진을 더 선명하게 찍어 다시 시도해 주세요.';
    }
    return raw.length > 90 ? '영수증 인식에 실패했습니다. 다시 시도해 주세요.' : raw;
  }

  void _syncUnitFromTotalAndQty() {
    if (_suppressUnitFromTotal) return;
    final totalRaw = _itemDraftTotalController.text.replaceAll(',', '').trim();
    if (totalRaw.isEmpty) return;
    final total = double.tryParse(totalRaw);
    final qtyRaw = _itemDraftQtyController.text.replaceAll(',', '').trim();
    final qty = double.tryParse(qtyRaw);
    if (total == null || total < 0 || qty == null || qty <= 0) return;
    final unit = total / qty;
    final next = _formatDerivedUnitPrice(unit);
    if (_itemDraftPriceController.text != next) {
      _suppressTotalFromUnit = true;
      _itemDraftPriceController.text = next;
      _suppressTotalFromUnit = false;
    }
  }

  void _syncTotalFromUnitAndQty() {
    if (_suppressTotalFromUnit) return;
    final unitRaw = _itemDraftPriceController.text.replaceAll(',', '').trim();
    final unit = double.tryParse(unitRaw);
    final qtyRaw = _itemDraftQtyController.text.replaceAll(',', '').trim();
    final qty = double.tryParse(qtyRaw);
    if (unit == null || unit < 0 || qty == null || qty <= 0) return;
    final next = _formatDerivedUnitPrice(unit * qty);
    if (_itemDraftTotalController.text != next) {
      _suppressUnitFromTotal = true;
      _itemDraftTotalController.text = next;
      _suppressUnitFromTotal = false;
    }
  }

  static String _formatDerivedUnitPrice(double u) {
    if (u.isNaN || u.isInfinite) return '';
    if ((u - u.round()).abs() < 1e-9) return '${u.round()}';
    var s = u.toStringAsFixed(4);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }

  @override
  void dispose() {
    _estimateDebounce?.cancel();
    _amountController.removeListener(_onReceiptAmountChanged);
    _cashExchangeFeeController.removeListener(_scheduleServerPaymentEstimate);
    _paymentCorrectionController.removeListener(_scheduleServerPaymentEstimate);
    _actualKrwController.removeListener(_scheduleServerPaymentEstimate);
    _itemDraftTotalController.removeListener(_syncUnitFromTotalAndQty);
    _itemDraftQtyController.removeListener(_onItemDraftQtyChanged);
    _itemDraftPriceController.removeListener(_onItemDraftUnitChanged);
    _storeController.dispose();
    _amountController.dispose();
    _cardIssuerController.dispose();
    _bankNameController.dispose();
    _cardBrandController.dispose();
    _cardLast4Controller.dispose();
    _cashExchangeFeeController.dispose();
    _paymentCorrectionController.dispose();
    _actualKrwController.dispose();
    _itemDraftNameController.dispose();
    _itemDraftTotalController.dispose();
    _itemDraftQtyController.dispose();
    _itemDraftPriceController.dispose();
    _personQtyDraftValues.clear();
    _ocr.dispose();
    super.dispose();
  }

  void _syncPersonQtyDraftValues(Iterable<String> participants) {
    final set = participants.toSet();
    _personQtyDraftValues.removeWhere((key, _) => !set.contains(key));
    for (final p in participants) {
      _personQtyDraftValues.putIfAbsent(p, () => 0);
    }
  }

  void _assignEvenSplitToAllTargets(Iterable<String> participants) {
    final names = participants.toList();
    if (names.isEmpty) return;
    _distributeEvenQtyAmong(
      names.toSet(),
      participantOrder: names,
    );
  }

  void _clearItemDraftFields() {
    _itemDraftNameController.clear();
    _itemDraftTotalController.clear();
    _itemDraftQtyController.text = '1';
    _itemDraftPriceController.clear();
    for (final k in _personQtyDraftValues.keys.toList()) {
      _personQtyDraftValues[k] = 0;
    }
    _showAdvancedSplit = false;
  }

  Map<String, double> _readQuantityByPerson(
    List<String> participants, {
    required double splitItemQuantity,
  }) {
    if (participants.isEmpty) return {};

    /// 저장 시점의 참가자 명단과 초안 맵 키를 맞춘다(편집/동기화 누락으로 키가 비는 경우 방지).
    _syncPersonQtyDraftValues(participants);

    if (!_showAdvancedSplit) {
      _assignEvenSplitToSelectedTargets(participants: participants);
    }
    final out = <String, double>{};
    for (final p in participants) {
      final v = _personQtyDraftValues[p] ?? 0;
      if (v != 0) out[p] = v;
    }

    /// 칩·상세 모두에서 정산 대상이 비어 있으면 저장 시 전원 균등(n빵).
    if (out.isEmpty) {
      final qtyResolved = splitItemQuantity;
      final ordered = List<String>.from(participants);
      final each = qtyResolved / ordered.length;
      out.clear();
      for (var i = 0; i < ordered.length; i++) {
        final p = ordered[i];
        final share = i == ordered.length - 1
            ? qtyResolved - each * (ordered.length - 1)
            : each;
        _personQtyDraftValues[p] = share;
        out[p] = share;
      }
    }
    return out;
  }

  void _applyQuantityByPersonToDraft(Map<String, double> byPerson) {
    for (final entry in byPerson.entries) {
      _personQtyDraftValues[entry.key] = entry.value;
    }
    for (final p in _personQtyDraftValues.keys.toList()) {
      if (!byPerson.containsKey(p)) {
        _personQtyDraftValues[p] = 0;
      }
    }
  }

  /// 품목 정산에 쓸 참가자 목록. 서버 `participants`가 비어 있어도 저장할 수 있게 host·결제자로 보완한다.
  List<String> _participantsForItemSettlement(Trip trip) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in trip.participants) {
      final p = raw.trim();
      if (p.isEmpty || seen.contains(p)) continue;
      seen.add(p);
      out.add(p);
    }
    if (out.isNotEmpty) return out;

    final host = trip.hostName.trim();
    if (host.isNotEmpty) return [host];

    final payer = (_paidBy ?? '').trim();
    if (payer.isNotEmpty) return [payer];

    return [];
  }

  bool get _canEditCurrentPaymentDetails {
    final user = context.read<UserProvider>().currentUser;
    final trip = context.read<TripProvider>().getTrip(widget.tripId);
    if (user == null || trip == null) return false;
    final isHost = user.matchesParticipantName(trip.hostName);
    final receipt = widget.receipt;
    return widget.receipt == null ||
        isHost ||
        (receipt != null && user.matchesParticipantName(receipt.paidBy));
  }

  /// 균등 배분 칩/수량 연동. 정수 나눗셈(`~/`)은 수량·인원에 따라 일부만 1단위를 받고
  /// 나머지는 0이 되어 칩이 꺼진 것처럼 보이므로, 실수로 `qty/n`을 나눈다.
  void _distributeEvenQtyAmong(
    Set<String> targets, {
    required List<String> participantOrder,
  }) {
    if (targets.isEmpty) return;
    final qty = _parseDraftItemQuantity() ?? 1;
    final each = qty / targets.length;
    final ordered = <String>[];
    for (final p in participantOrder) {
      if (targets.contains(p)) ordered.add(p);
    }
    for (final t in targets) {
      if (!ordered.contains(t)) ordered.add(t);
    }
    for (final p in _personQtyDraftValues.keys.toList()) {
      if (!targets.contains(p)) {
        _personQtyDraftValues[p] = 0;
      }
    }
    for (var i = 0; i < ordered.length; i++) {
      final p = ordered[i];
      if (i == ordered.length - 1) {
        var prior = 0.0;
        for (var j = 0; j < ordered.length - 1; j++) {
          prior += each;
        }
        _personQtyDraftValues[p] = qty - prior;
      } else {
        _personQtyDraftValues[p] = each;
      }
    }
  }

  void _assignEvenSplitToSelectedTargets({Iterable<String>? participants}) {
    final names = (participants ?? _personQtyDraftValues.keys).toList();
    if (names.isEmpty) return;
    final selected =
        names.where((p) => (_personQtyDraftValues[p] ?? 0) > 0).toList();
    if (selected.isEmpty) {
      _assignEvenSplitToAllTargets(names);
      return;
    }
    _distributeEvenQtyAmong(
      selected.toSet(),
      participantOrder: names,
    );
  }

  void _toggleSplitTarget(String participant, bool selected) {
    final currentTargets = _personQtyDraftValues.entries
        .where((e) => e.value > 0)
        .map((e) => e.key)
        .toSet();
    if (selected) {
      currentTargets.add(participant);
    } else {
      currentTargets.remove(participant);
    }
    if (currentTargets.isEmpty) {
      setState(() {
        _assignEvenSplitToAllTargets(_personQtyDraftValues.keys);
      });
      return;
    }

    setState(() {
      _distributeEvenQtyAmong(
        currentTargets,
        participantOrder: _personQtyDraftValues.keys.toList(),
      );
    });
  }

  bool _isEvenSplitForItem(ReceiptItem item) {
    final values = item.quantityByPerson.values.where((v) => v > 0).toList();
    if (values.isEmpty) return true;
    final each = item.quantity / values.length;
    return values.every((v) => (v - each).abs() < 1e-6);
  }

  /// 품목 수량이 [participants] 전원에게 동일하게 나뉜 경우(저장 시 전원 n빵 등).
  bool _isEvenSplitAcrossParticipants(
    ReceiptItem item,
    List<String> participants,
  ) {
    if (participants.isEmpty) return false;
    if (participants.length == 1) {
      final v = item.quantityByPerson[participants.first] ?? 0;
      return (v - item.quantity).abs() < 1e-5;
    }
    final each = item.quantity / participants.length;
    for (final p in participants) {
      final v = item.quantityByPerson[p] ?? 0;
      if ((v - each).abs() > 1e-5) return false;
    }
    return true;
  }

  double get _receiptAmountValue =>
      double.tryParse(_amountController.text.replaceAll(',', '').trim()) ?? 0;

  double? _parseActualKrwAmount() {
    final raw = _actualKrwController.text.replaceAll(',', '').trim();
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  double? _parseCashKrwPerUnit() {
    final raw = _cashExchangeFeeController.text.replaceAll(',', '').trim();
    if (raw.isEmpty) return null;
    final parsed = double.tryParse(raw);
    return parsed == null || parsed <= 0 ? null : parsed;
  }

  static String _formatRatePercentInput(double? rate) {
    if (rate == null || rate == 0) return '';
    var s = (rate * 100).toStringAsFixed(2);
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return s;
  }

  static String _formatNumberInput(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    var s = value.toStringAsFixed(4);
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return s;
  }

  static String _formatCurrencyInput(double value, String currencyCode) {
    final digits = currencyFractionDigits(currencyCode);
    if (digits == 0 || value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    var s = value.toStringAsFixed(digits);
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return s;
  }

  PaymentEstimate get _localPaymentEstimate => estimatePayment(
        amount: _receiptAmountValue,
        currencyCode: _currencyCode,
        paymentMethod: _paymentMethod,
        cardType: _selectedCardProfile?.cardType ?? 'credit',
        cardIssuer: _cardIssuerController.text.trim(),
        cardBrand: _cardBrandController.text.trim(),
        cardIssuerFeeRate: _selectedCardProfile?.issuerFeeRate,
        cardBrandFeeRate: _selectedCardProfile?.brandFeeRate,
        issuerFeeType: _selectedCardProfile?.issuerFeeType,
        issuerFeeFixedUsd: _selectedCardProfile?.issuerFeeFixedUsd,
        cashKrwPerUnit: _parseCashKrwPerUnit(),
        actualKrwAmount: _paymentMethod == paymentMethodCard
            ? _parseActualKrwAmount()
            : null,
      );

  PaymentEstimate get _paymentEstimate =>
      _serverPaymentEstimate ?? _localPaymentEstimate;

  Receipt _paymentEstimateReceiptPayload() {
    return Receipt(
      id: widget.receipt?.id ?? _persistedReceiptId ?? 'preview',
      storeName: _storeController.text.trim(),
      amount: _receiptAmountValue,
      date: _date,
      category: _category,
      imagePath: _imagePath,
      recognition: _recognition,
      paidBy: _paidBy ?? '',
      currencyCode: _currencyCode,
      paymentMethod: _paymentMethod,
      cardType: _selectedCardProfile?.cardType ??
          widget.receipt?.cardType ??
          'credit',
      cardIssuer: _paymentMethod == paymentMethodCash ||
              _cardIssuerController.text.trim().isEmpty
          ? null
          : _cardIssuerController.text.trim(),
      bankName: _paymentMethod == paymentMethodCash ||
              _bankNameController.text.trim().isEmpty
          ? null
          : _bankNameController.text.trim(),
      cardBrand: _paymentMethod == paymentMethodCash ||
              _cardBrandController.text.trim().isEmpty
          ? null
          : _cardBrandController.text.trim(),
      cardLast4: _paymentMethod == paymentMethodCash ||
              _cardLast4Controller.text.trim().isEmpty
          ? null
          : _cardLast4Controller.text.trim(),
      cardBrandFeeRate: _paymentMethod == paymentMethodCard
          ? _selectedCardProfile?.brandFeeRate
          : null,
      cardIssuerFeeRate: _paymentMethod == paymentMethodCard
          ? _selectedCardProfile?.issuerFeeRate
          : null,
      issuerFeeType: _paymentMethod == paymentMethodCard
          ? _selectedCardProfile?.issuerFeeType
          : null,
      issuerFeeFixedUsd: _paymentMethod == paymentMethodCard
          ? _selectedCardProfile?.issuerFeeFixedUsd
          : null,
      cashKrwPerUnit:
          _paymentMethod == paymentMethodCash ? _parseCashKrwPerUnit() : null,
      actualKrwAmount:
          _paymentMethod == paymentMethodCard ? _parseActualKrwAmount() : null,
      items: const [],
    );
  }

  void _scheduleServerPaymentEstimate() {
    _estimateDebounce?.cancel();
    _estimateDebounce = Timer(
      const Duration(milliseconds: 650),
      _refreshServerPaymentEstimate,
    );
  }

  Future<void> _refreshServerPaymentEstimate() async {
    if (!mounted) return;
    final serial = ++_estimateRequestSerial;
    if (!_isEstimateRefreshing) {
      setState(() => _isEstimateRefreshing = true);
    }
    try {
      final estimate = await context
          .read<ApiService>()
          .estimateReceiptPayment(_paymentEstimateReceiptPayload());
      if (!mounted || serial != _estimateRequestSerial) return;
      setState(() {
        _serverPaymentEstimate = estimate;
        _isEstimateRefreshing = false;
      });
    } catch (_) {
      if (!mounted || serial != _estimateRequestSerial) return;
      setState(() => _isEstimateRefreshing = false);
    }
  }

  double get _itemsLineTotal =>
      _items.fold(0.0, (sum, item) => sum + item.lineTotal);

  double get _amountDifference => _receiptAmountValue - _itemsLineTotal;

  double get _amountMatchTolerance => _currencyCode == 'KRW' ? 1 : 0.01;

  bool get _hasAmountMismatch =>
      _items.isNotEmpty && _amountDifference.abs() > _amountMatchTolerance;

  Widget _amountMatchStatus(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasItems = _items.isNotEmpty;
    final matched = hasItems && !_hasAmountMismatch;
    final tone = !hasItems
        ? scheme.surfaceContainerHighest
        : matched
            ? scheme.primaryContainer
            : scheme.errorContainer;
    final foreground = !hasItems
        ? scheme.onSurfaceVariant
        : matched
            ? scheme.onPrimaryContainer
            : scheme.onErrorContainer;
    final title = !hasItems
        ? '품목을 추가하면 총액과 합계를 비교합니다.'
        : matched
            ? '영수증 총액과 품목 합계가 일치합니다.'
            : '영수증 총액과 품목 합계가 다릅니다.';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: foreground.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                matched
                    ? Icons.check_circle_outline
                    : hasItems
                        ? Icons.error_outline
                        : Icons.info_outline,
                size: 18,
                color: foreground,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
          if (hasItems) ...[
            const SizedBox(height: 8),
            Text(
              '총액 ${formatMoneyLabel(_receiptAmountValue, _currencyCode)} · '
              '품목 합계 ${formatMoneyLabel(_itemsLineTotal, _currencyCode)} · '
              '차이 ${formatMoneyLabel(_amountDifference.abs(), _currencyCode)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: foreground,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatStepperQty(double v) {
    final rounded = roundCurrencyAmount(v, _currencyCode);
    if (rounded == 0) return '0';
    if ((rounded - rounded.round()).abs() < 1e-9) return '${rounded.round()}';
    var s = rounded.toStringAsFixed(currencyFractionDigits(_currencyCode));
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }

  double? _parseDraftItemQuantity() {
    final raw = _itemDraftQtyController.text.replaceAll(',', '').trim();
    if (raw.isEmpty) return null;
    final q = double.tryParse(raw);
    if (q == null || q <= 0) return null;
    return q;
  }

  DateTime _clampDateToTrip(DateTime value, trip) {
    final first = DateTime(
      trip.startDate.year,
      trip.startDate.month,
      trip.startDate.day,
      value.hour,
      value.minute,
    );
    final last = DateTime(
      trip.endDate.year,
      trip.endDate.month,
      trip.endDate.day,
      value.hour,
      value.minute,
    );
    if (value.isBefore(first)) return first;
    if (value.isAfter(last)) return last;
    return value;
  }

  Future<void> _pickReceiptDate(trip) async {
    if (!mounted) return;
    final initial = _clampDateToTrip(_date, trip);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: trip.startDate,
      lastDate: trip.endDate,
    );
    if (picked == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_date),
    );
    if (time == null) return;
    setState(() {
      _didUserChooseDate = true;
      _date = DateTime(
        picked.year,
        picked.month,
        picked.day,
        time.hour,
        time.minute,
      );
    });
    _scheduleServerPaymentEstimate();
  }

  String get _amountHintText {
    switch (_currencyCode) {
      case 'KRW':
        return '예: 15000';
      case 'JPY':
        return '예: 1200';
      case 'VND':
        return '예: 250000';
      case 'USD':
      case 'EUR':
      case 'GBP':
      case 'CHF':
      case 'AUD':
      case 'CAD':
      case 'SGD':
        return '예: 24.50';
      default:
        return '예: 100';
    }
  }

  String get _cashRateHintText {
    final rate = exchangeRateFor(_currencyCode);
    if (rate <= 0 || _currencyCode == 'KRW') return '예: 1';
    return '예: ${_formatNumberInput(rate)}';
  }

  void _setCurrency(String value) {
    setState(() {
      _currencyCode = value;
      _didUserChooseCurrency = true;
    });
    _scheduleServerPaymentEstimate();
  }

  double _sumPersonQtyDraft() {
    var s = 0.0;
    for (final v in _personQtyDraftValues.values) {
      s += v;
    }
    return s;
  }

  /// 품목 수량만큼 인원별 합이 배분되면 더 이상 늘릴 수 없음
  bool _isPersonQtyIncrementBlocked() {
    final cap = _parseDraftItemQuantity();
    if (cap == null) return false;
    return _sumPersonQtyDraft() >= cap - 1e-9;
  }

  Widget _personQtyStepper(
    BuildContext context,
    String participant, {
    VoidCallback? onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final v = _personQtyDraftValues[participant] ?? 0;
    final canDec = v > 0;
    final atCap = _isPersonQtyIncrementBlocked();
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
        color: scheme.surfaceContainerLowest,
      ),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '한 개 줄이기',
            onPressed: canDec
                ? () {
                    setState(() {
                      final next = v - 1;
                      _personQtyDraftValues[participant] = next < 0 ? 0 : next;
                    });
                    onChanged?.call();
                  }
                : null,
            icon: const Icon(Icons.remove),
          ),
          Expanded(
            child: Text(
              _formatStepperQty(v),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: atCap ? '품목 수량만큼 모두 배분됨' : '한 개 늘리기',
            onPressed: atCap
                ? null
                : () {
                    setState(() {
                      _personQtyDraftValues[participant] = v + 1;
                    });
                    onChanged?.call();
                  },
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  Widget _paymentEstimatePanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final estimate = _paymentEstimate;
    final brandRule = findBrandFeeRule(_cardBrandController.text);
    final issuerRule = findIssuerFeeRule(_cardIssuerController.text);
    final isCard = estimate.paymentMethod == paymentMethodCard;
    final headline = estimate.actualKrwAmount != null
        ? '정산 반영액 ${formatWonLabel(estimate.settlementKrwAmount)}'
        : '예상 정산액 ${formatWonLabel(estimate.settlementKrwAmount)}';
    final isKrw = estimate.currencyCode == 'KRW';
    final sourceLabel =
        '${estimate.rateDateLabel} · ${estimate.exchangeRateSource}';
    final details = <MapEntry<String, String>>[];
    if (isKrw) {
      details.add(
        MapEntry(
          '원화 결제',
          '${formatMoneyLabel(estimate.foreignAmount, 'KRW')} → ${formatWonLabel(estimate.baseKrwAmount)}',
        ),
      );
      details.add(const MapEntry('수수료', '해외결제 수수료 미적용'));
    } else if (isCard) {
      details.add(
        MapEntry(
          '${estimate.currencyCode} → USD',
          '1 ${estimate.currencyCode} = ${_formatNumberInput(estimate.localToUsdRate)} USD · ${formatMoneyLabel(estimate.foreignAmount, estimate.currencyCode)} → ${formatMoneyLabel(estimate.usdAmount, 'USD')}',
        ),
      );
      details.add(
        MapEntry(
          'USD → KRW',
          '1 USD = ${_formatNumberInput(estimate.usdToKrwRate)}원 · ${formatMoneyLabel(estimate.usdAmount, 'USD')} → ${formatWonLabel(estimate.baseKrwAmount)}',
        ),
      );
      details.add(
        MapEntry(
          '국제브랜드',
          '${brandRule?.label ?? '브랜드'} ${formatFeeRate(estimate.cardBrandFeeRate)} · +${formatWonLabel(estimate.cardBrandFeeKrw)}',
        ),
      );
      details.add(
        MapEntry(
          '카드사',
          estimate.issuerFeeType == 'fixed_usd'
              ? '${issuerRule?.label ?? '카드사'} 건당 ${formatMoneyLabel(estimate.issuerFeeFixedUsd, 'USD')} · +${formatWonLabel(estimate.cardIssuerFeeKrw)}'
              : '${issuerRule?.label ?? '카드사'} ${formatFeeRate(estimate.cardIssuerFeeRate)} · +${formatWonLabel(estimate.cardIssuerFeeKrw)}',
        ),
      );
    } else {
      details.add(
        MapEntry(
          '${estimate.currencyCode} → KRW',
          estimate.cashKrwPerUnit > 0
              ? '입력 환율 1 ${estimate.currencyCode} = ${_formatNumberInput(estimate.cashKrwPerUnit)}원 · ${formatMoneyLabel(estimate.foreignAmount, estimate.currencyCode)} → ${formatWonLabel(estimate.baseKrwAmount)}'
              : '1 ${estimate.currencyCode} = ${_formatNumberInput(estimate.baseKrwAmount / (estimate.foreignAmount == 0 ? 1 : estimate.foreignAmount))}원 · ${formatMoneyLabel(estimate.foreignAmount, estimate.currencyCode)} → ${formatWonLabel(estimate.baseKrwAmount)}',
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                setState(() {
                  _paymentEstimateExpanded = !_paymentEstimateExpanded;
                });
              },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      isCard ? Icons.currency_exchange : Icons.savings_outlined,
                      size: 22,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        headline,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurface,
                                ),
                      ),
                    ),
                    if (_isEstimateRefreshing) ...[
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Text(
                      _paymentEstimateExpanded ? '간단히' : '자세히',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.primary,
                          ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      _paymentEstimateExpanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: scheme.primary,
                      size: 22,
                    ),
                  ],
                ),
              ),
            ),
          ),
          ClipRect(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _paymentEstimateExpanded
                  ? Column(
                      key: const ValueKey('estimate_details'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 10),
                        ...details.map(
                          (item) => Padding(
                            padding: const EdgeInsets.only(bottom: 7),
                            child: _estimateDetailBlock(
                              context,
                              item.key,
                              item.value,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: _estimateDetailBlock(
                              context, '환율 기준', sourceLabel),
                        ),
                        if (_isEstimateRefreshing) ...[
                          const SizedBox(height: 4),
                          Text(
                            '서버 계산값을 갱신하는 중입니다.',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                          ),
                        ],
                        if (estimate.actualKrwAmount != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            '실제 청구액을 우선 정산에 반영합니다.',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: scheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                          ),
                        ],
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _estimateDetailBlock(
    BuildContext context,
    String title,
    String value,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.35,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  String? get _recognitionDurationLabel {
    final raw = _recognition?['durationMs'] ??
        _recognition?['elapsedMs'] ??
        _recognition?['processingMs'];
    final ms = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (ms == null || ms <= 0) return null;
    if (ms >= 1000) return '${(ms / 1000).toStringAsFixed(1)}초';
    return '${ms.toStringAsFixed(0)}ms';
  }

  String get _formattedReceiptDateTimeDisplay =>
      '${_date.year}.${_date.month.toString().padLeft(2, '0')}.${_date.day.toString().padLeft(2, '0')} '
      '${_date.hour.toString().padLeft(2, '0')}:${_date.minute.toString().padLeft(2, '0')}';

  String _currencyFlag(String code) {
    return switch (code.toUpperCase()) {
      'KRW' => '🇰🇷',
      'USD' => '🇺🇸',
      'EUR' => '🇪🇺',
      'JPY' => '🇯🇵',
      'CNY' => '🇨🇳',
      'GBP' => '🇬🇧',
      'CHF' => '🇨🇭',
      'SEK' => '🇸🇪',
      'NOK' => '🇳🇴',
      'DKK' => '🇩🇰',
      'ISK' => '🇮🇸',
      'PLN' => '🇵🇱',
      'CZK' => '🇨🇿',
      'HUF' => '🇭🇺',
      _ => '🏳️',
    };
  }

  String _currencyOptionLabel(String code) => '${_currencyFlag(code)} $code';

  /// 대표자·결제자 외: 상호·카테고리·금액만 텍스트로 표시 (같은 카드의 결제 수단 영역은 그대로 유지)
  Widget _buildCompressedReceiptBasics(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final raw = _storeController.text.trim();
    final storePart = raw.isEmpty ? '---' : raw;
    final t = Theme.of(context).textTheme;
    final storeStyle = (t.titleMedium ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w800,
      fontSize: (t.titleMedium?.fontSize ?? 17) + 2,
      height: 1.25,
      color: scheme.onSurface,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '상호명: ',
                  style: t.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                TextSpan(text: storePart, style: storeStyle),
                TextSpan(
                  text: ' ($_category)',
                  style: t.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          formatMoneyLabel(_receiptAmountValue, _currencyCode),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final trip = context.watch<TripProvider>().getTrip(widget.tripId);
    final user = context.watch<UserProvider>().currentUser;
    final currentUserName = user?.displayName;
    if (trip == null) {
      return const Scaffold(body: Center(child: Text('여행을 찾을 수 없습니다')));
    }

    final settlementPeopleForItems = _participantsForItemSettlement(trip);
    _syncPersonQtyDraftValues(settlementPeopleForItems);
    final isHost = user != null && user.matchesParticipantName(trip.hostName);
    final canEditPaymentDetails = widget.receipt == null ||
        isHost ||
        (user != null && user.matchesParticipantName(widget.receipt!.paidBy));
    final canChoosePayer = canEditPaymentDetails && isHost;
    final payerItems = canChoosePayer
        ? <String>[
            if (_paidBy != null && _paidBy!.isNotEmpty) _paidBy!,
            ...trip.participants,
          ]
        : <String>[
            if (_paidBy != null && _paidBy!.isNotEmpty)
              _paidBy!
            else if (currentUserName != null && currentUserName.isNotEmpty)
              currentUserName,
          ];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.receipt == null ? '영수증 추가' : '영수증 수정'),
        actions: [
          if (widget.receipt != null && canEditPaymentDetails)
            IconButton(
              icon: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => _confirmDelete(context),
            ),
          TextButton(
            onPressed: _isImageUploading || _isAutoSaving ? null : _save,
            child: Text(_isAutoSaving ? '저장 중' : '저장'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            GestureDetector(
              onTap: _imagePath != null
                  ? _showReceiptImageViewer
                  : (canEditPaymentDetails ? _pickImage : null),
              child: Container(
                height: 160,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: _imagePath != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _receiptImagePreview(_imagePath!),
                            if (_isImageUploading)
                              Container(
                                color: Colors.black.withValues(alpha: 0.32),
                                child: const Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                            Positioned(
                              right: 8,
                              top: 8,
                              child: IconButton.filled(
                                icon: const Icon(Icons.add),
                                onPressed:
                                    canEditPaymentDetails ? _pickImage : null,
                              ),
                            ),
                          ],
                        ),
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.add_a_photo,
                            size: 48,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '영수증 사진 촬영/선택',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                          if (_isOcrLoading)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: CircularProgressIndicator(),
                            ),
                        ],
                      ),
              ),
            ),
            if (_imagePath != null || _ocrStatusMessage != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      [
                        _ocrStatusMessage ?? '사진을 바탕으로 영수증 정보를 자동 입력할 수 있습니다.',
                        if (_recognitionDurationLabel != null)
                          '인식 시간 ${_recognitionDurationLabel!}',
                        if (_isAutoSaving) '자동 저장 중',
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: canEditPaymentDetails &&
                            !_isOcrLoading &&
                            !_isImageUploading &&
                            _imagePath != null
                        ? _recognizeCurrentReceiptImage
                        : null,
                    icon: _isOcrLoading
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          )
                        : const Icon(Icons.auto_awesome),
                    label: Text(_isOcrLoading ? '인식 중' : '다시 인식'),
                  ),
                ],
              ),
            ],
            if (_recognitionConfidence != null ||
                _recognitionWarnings.isNotEmpty) ...[
              const SizedBox(height: 10),
              _RecognitionQualityPanel(
                confidence: _recognitionConfidence,
                warnings: _recognitionWarnings,
              ),
            ],
            const SizedBox(height: 16),
            if (canEditPaymentDetails)
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 56,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _pickReceiptDate(trip),
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: '결제 일시',
                            border: OutlineInputBorder(),
                            isDense: true,
                            contentPadding: _fieldPadding,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _formattedReceiptDateTimeDisplay,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: SizedBox(
                      height: 56,
                      child: DropdownButtonFormField<String>(
                        initialValue: _paidBy,
                        isExpanded: true,
                        isDense: true,
                        decoration: const InputDecoration(
                          labelText: '결제자',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: _fieldPadding,
                        ),
                        items: payerItems
                            .toSet()
                            .map((p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(
                                    p,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ))
                            .toList(),
                        onChanged: canChoosePayer ? _setPaidBy : null,
                        validator: (v) => v == null ? '결제자를 선택하세요' : null,
                      ),
                    ),
                  ),
                ],
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '결제 일시',
                          style:
                              Theme.of(context).textTheme.labelMedium?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formattedReceiptDateTimeDisplay,
                          style:
                              Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    height: 1.3,
                                  ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '결제자',
                          style:
                              Theme.of(context).textTheme.labelMedium?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          (_paidBy != null && _paidBy!.trim().isNotEmpty)
                              ? _paidBy!
                              : '—',
                          style:
                              Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    height: 1.3,
                                    fontWeight: FontWeight.w600,
                                  ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '영수증 정보',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    if (!canEditPaymentDetails) ...[
                      const SizedBox(height: 6),
                      Text(
                        '결제 정보는 대표자와 ${widget.receipt!.paidBy}만 수정할 수 있습니다.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (canEditPaymentDetails) ...[
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              controller: _storeController,
                              decoration: const InputDecoration(
                                labelText: '상호명',
                                hintText: '예: 스타벅스 강남점',
                                border: OutlineInputBorder(),
                                isDense: true,
                                contentPadding: _fieldPadding,
                              ),
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? '상호명을 입력하세요'
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 1,
                            child: DropdownButtonFormField<String>(
                              initialValue: _category,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '카테고리',
                                border: OutlineInputBorder(),
                                isDense: true,
                                contentPadding: _fieldPadding,
                              ),
                              items: _categories
                                  .map((c) => DropdownMenuItem(
                                        value: c,
                                        child: Text(c),
                                      ))
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _category = v ?? '식비'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              controller: _amountController,
                              decoration: InputDecoration(
                                labelText: '금액',
                                hintText: _amountHintText,
                                border: const OutlineInputBorder(),
                                suffixText: _currencyCode,
                                isDense: true,
                                contentPadding: _fieldPadding,
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              validator: (v) {
                                if (v == null || v.isEmpty) {
                                  return '금액을 입력하세요';
                                }
                                if (double.tryParse(v.replaceAll(',', '')) ==
                                    null) {
                                  return '숫자를 입력하세요';
                                }
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 1,
                            child: DropdownButtonFormField<String>(
                              initialValue: _currencyCode,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '통화',
                                border: OutlineInputBorder(),
                                isDense: true,
                                contentPadding: _fieldPadding,
                              ),
                              items: supportedCurrencyCodes
                                  .map((c) => DropdownMenuItem(
                                        value: c,
                                        child: Text(_currencyOptionLabel(c)),
                                      ))
                                  .toList(),
                              onChanged: (v) => _setCurrency(v ?? 'KRW'),
                            ),
                          ),
                        ],
                      ),
                    ] else
                      _buildCompressedReceiptBasics(context),
                    const SizedBox(height: 12),
                    if (canEditPaymentDetails) ...[
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: paymentMethodCard,
                            icon: Icon(Icons.credit_card),
                            label: Text('카드'),
                          ),
                          ButtonSegment(
                            value: paymentMethodCash,
                            icon: Icon(Icons.payments_outlined),
                            label: Text('현금'),
                          ),
                        ],
                        selected: {_paymentMethod},
                        onSelectionChanged: (values) {
                          setState(() {
                            _paymentMethod = values.first;
                            if (_paymentMethod == paymentMethodCash) {
                              _selectedCardId = null;
                              _cardIssuerController.clear();
                              _bankNameController.clear();
                              _cardBrandController.clear();
                              _cardLast4Controller.clear();
                              _actualKrwController.clear();
                            } else {
                              _cashExchangeFeeController.clear();
                            }
                          });
                          _scheduleServerPaymentEstimate();
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_paymentMethod == paymentMethodCard &&
                        canEditPaymentDetails) ...[
                      DropdownButtonFormField<String>(
                        key: ValueKey(
                            'card_${_selectedCardId ?? 'none'}_${_cards.length}'),
                        initialValue: _selectedCardId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '결제 카드',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: _fieldPadding,
                        ),
                        items: [
                          const DropdownMenuItem<String>(
                            value: null,
                            child: Text('선택 안 함'),
                          ),
                          ..._cards.map(
                            (card) => DropdownMenuItem<String>(
                              value: card.id,
                              child: Text(
                                card.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged:
                            canEditPaymentDetails ? _applyCardProfile : null,
                      ),
                      if (_cards.isEmpty && canEditPaymentDetails) ...[
                        const SizedBox(height: 8),
                        Text(
                          '마이페이지에서 카드를 등록하면 여기서 바로 선택할 수 있습니다.',
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ] else if (_paymentMethod == paymentMethodCard) ...[
                      Text(
                        '결제 카드는 대표자와 결제자에게만 표시됩니다.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ] else if (_paymentMethod == paymentMethodCash &&
                        canEditPaymentDetails) ...[
                      TextFormField(
                        controller: _cashExchangeFeeController,
                        decoration: InputDecoration(
                          labelText: '환전 적용 환율',
                          hintText: _cashRateHintText,
                          suffixText: '원 / $_currencyCode',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          contentPadding: _fieldPadding,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) => setState(() {}),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return null;
                          return double.tryParse(v.trim()) == null
                              ? '숫자를 입력하세요'
                              : null;
                        },
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (_paymentMethod == paymentMethodCard &&
                        canEditPaymentDetails) ...[
                      TextFormField(
                        controller: _actualKrwController,
                        enabled: canEditPaymentDetails,
                        decoration: const InputDecoration(
                          labelText: '실제 청구액',
                          hintText: '카드사 앱 청구액',
                          suffixText: '원',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: _fieldPadding,
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return null;
                          return double.tryParse(
                                    v.replaceAll(',', '').trim(),
                                  ) ==
                                  null
                              ? '숫자를 입력하세요'
                              : null;
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    _paymentEstimatePanel(context),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '품목',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 8),
                    _amountMatchStatus(context),
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      onPressed: () => _openItemEditor(),
                      icon: const Icon(Icons.add),
                      label: const Text('품목 추가'),
                    ),
                    const SizedBox(height: 12),
                    if (_items.isNotEmpty) ...[
                      ...List.generate(_items.length, (i) {
                        final item = _items[i];
                        final editing = _editingItemIndex == i;
                        final scheme = Theme.of(context).colorScheme;
                        final subtitle = item.quantity == 1
                            ? formatMoneyLabel(item.lineTotal, _currencyCode)
                            : '${formatMoneyLabel(item.unitPrice, _currencyCode)} × ${_formatStepperQty(item.quantity)} = ${formatMoneyLabel(item.lineTotal, _currencyCode)}';
                        final allParticipantSettlementQtyIsZero =
                            settlementPeopleForItems.isEmpty ||
                                !settlementPeopleForItems.any((person) {
                                  final qr = roundCurrencyAmount(
                                    item.quantityByPerson[person] ?? 0,
                                    _currencyCode,
                                  );
                                  return qr > 0;
                                });
                        final showWholeGroupEvenSplit =
                            allParticipantSettlementQtyIsZero ||
                                _isEvenSplitAcrossParticipants(
                                  item,
                                  settlementPeopleForItems,
                                );
                        final thinSettlementRowStyle =
                            Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontSize: 12,
                                      height: 1.2,
                                      color: scheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w400,
                                    ) ??
                                TextStyle(
                                  fontSize: 12,
                                  height: 1.2,
                                  color: scheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w400,
                                );
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Material(
                            color: editing
                                ? scheme.primaryContainer
                                    .withValues(alpha: 0.35)
                                : scheme.surfaceContainerLow,
                            clipBehavior: Clip.antiAlias,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: BorderSide(
                                color: editing
                                    ? scheme.primary.withValues(alpha: 0.65)
                                    : scheme.outlineVariant
                                        .withValues(alpha: 0.95),
                              ),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () => _openItemEditor(index: i),
                              child: Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(10, 10, 4, 10),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                item.name,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                              const SizedBox(height: 4),
                                              if (item.translatedName != null &&
                                                  item.translatedName!
                                                      .trim()
                                                      .isNotEmpty &&
                                                  item.translatedName!.trim() !=
                                                      item.name.trim()) ...[
                                                Text(
                                                  item.translatedName!.trim(),
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: scheme
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                                const SizedBox(height: 2),
                                              ],
                                              Text(
                                                subtitle,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: scheme
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          icon:
                                              const Icon(Icons.delete_outline),
                                          onPressed: () {
                                            setState(() {
                                              final was = _editingItemIndex;
                                              if (was == i) {
                                                _editingItemIndex = null;
                                                _clearItemDraftFields();
                                              } else if (was != null &&
                                                  was > i) {
                                                _editingItemIndex = was - 1;
                                              }
                                              _items.removeAt(i);
                                            });
                                          },
                                          tooltip: '삭제',
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '인원별 정산 수량',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    if (!showWholeGroupEvenSplit) ...[
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            flex: 1,
                                            child: Align(
                                              alignment: Alignment.centerLeft,
                                              child: Text(
                                                '이름',
                                                textAlign: TextAlign.left,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: scheme
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            flex: 1,
                                            child: Align(
                                              alignment: Alignment.centerLeft,
                                              child: Text(
                                                '수량',
                                                textAlign: TextAlign.left,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: scheme
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 4),
                                        child: Divider(
                                          height: 1,
                                          thickness: 1,
                                          color: scheme.outlineVariant
                                              .withValues(alpha: 0.45),
                                        ),
                                      ),
                                    ],
                                    if (showWholeGroupEvenSplit)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 3),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              flex: 1,
                                              child: Align(
                                                alignment: Alignment.centerLeft,
                                                child: Text(
                                                  '전원',
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  textAlign: TextAlign.left,
                                                  style: thinSettlementRowStyle,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              flex: 1,
                                              child: Align(
                                                alignment: Alignment.centerLeft,
                                                child: Text(
                                                  "1/N",
                                                  textAlign: TextAlign.left,
                                                  style: thinSettlementRowStyle,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    else
                                      ...settlementPeopleForItems
                                          .where((person) {
                                        final qr = roundCurrencyAmount(
                                          item.quantityByPerson[person] ?? 0,
                                          _currencyCode,
                                        );
                                        return qr > 0;
                                      }).map((p) {
                                        final q = item.quantityByPerson[p] ?? 0;
                                        return Padding(
                                          padding:
                                              const EdgeInsets.only(bottom: 3),
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Expanded(
                                                flex: 1,
                                                child: Align(
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  child: Text(
                                                    p,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    textAlign: TextAlign.left,
                                                    style:
                                                        thinSettlementRowStyle,
                                                  ),
                                                ),
                                              ),
                                              Expanded(
                                                flex: 1,
                                                child: Align(
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  child: Text(
                                                    _formatStepperQty(q),
                                                    textAlign: TextAlign.left,
                                                    style:
                                                        thinSettlementRowStyle
                                                            .copyWith(
                                                      fontFeatures: const [
                                                        FontFeature
                                                            .tabularFigures(),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      }),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _loadItemIntoDraft(int index, List<String> tripParticipants) {
    final item = _items[index];
    _suppressUnitFromTotal = true;
    _suppressTotalFromUnit = true;
    setState(() {
      _editingItemIndex = index;
      _itemDraftNameController.text = item.name;
      _itemDraftQtyController.text =
          item.quantity == item.quantity.roundToDouble()
              ? '${item.quantity.round()}'
              : '${item.quantity}';
      _itemDraftPriceController.text =
          item.unitPrice == item.unitPrice.roundToDouble()
              ? '${item.unitPrice.round()}'
              : '${item.unitPrice}';
      _itemDraftTotalController.text =
          item.lineTotal == item.lineTotal.roundToDouble()
              ? '${item.lineTotal.round()}'
              : '${item.lineTotal}';
      _syncPersonQtyDraftValues(tripParticipants);
      if (item.quantityByPerson.isEmpty) {
        _assignEvenSplitToAllTargets(tripParticipants);
      } else {
        _applyQuantityByPersonToDraft(item.quantityByPerson);
      }
      _showAdvancedSplit = !_isEvenSplitForItem(item);
    });
    _suppressUnitFromTotal = false;
    _suppressTotalFromUnit = false;
  }

  Future<void> _openItemEditor({int? index}) async {
    final trip = context.read<TripProvider>().getTrip(widget.tripId);
    if (trip == null) return;

    final settlementPeople = _participantsForItemSettlement(trip);

    var saved = false;
    if (index == null) {
      setState(() {
        _editingItemIndex = null;
        _clearItemDraftFields();
        _syncPersonQtyDraftValues(settlementPeople);
        _assignEvenSplitToAllTargets(settlementPeople);
      });
    } else {
      _loadItemIntoDraft(index, settlementPeople);
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            void refreshSheet() {
              if (mounted) setState(() {});
              setSheetState(() {});
            }

            return SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: MediaQuery.viewInsetsOf(sheetContext).bottom + 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            index == null ? '품목 추가' : '품목 수정',
                            style: Theme.of(sheetContext).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: '닫기',
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _itemDraftNameController,
                      textInputAction: TextInputAction.next,
                      style: _itemDraftValueStyle,
                      decoration: _itemDraftInputDecoration(
                        labelText: '품목명',
                        hintText: '예: 마라로제엽떡',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _itemDraftPriceController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setSheetState(() {}),
                            style: _itemDraftValueStyle,
                            decoration: _itemDraftInputDecoration(
                              labelText: '단가',
                              suffixText: _currencyCode,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _itemDraftQtyController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setSheetState(() {}),
                            style: _itemDraftValueStyle,
                            decoration: _itemDraftInputDecoration(
                              labelText: '수량',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _itemDraftTotalController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setSheetState(() {}),
                            style: _itemDraftValueStyle,
                            decoration: _itemDraftInputDecoration(
                              labelText: '총가격',
                              suffixText: _currencyCode,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '정산 대상',
                            style: Theme.of(sheetContext)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _showAdvancedSplit = !_showAdvancedSplit;
                              if (!_showAdvancedSplit) {
                                _assignEvenSplitToSelectedTargets(
                                  participants: settlementPeople,
                                );
                              }
                            });
                            setSheetState(() {});
                          },
                          icon: Icon(_showAdvancedSplit
                              ? Icons.tune
                              : Icons.tune_outlined),
                          label: Text(_showAdvancedSplit ? '균등 배분' : '상세 배분'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: settlementPeople.map((p) {
                        final selected = (_personQtyDraftValues[p] ?? 0) > 0;
                        return FilterChip(
                          label: Text(p),
                          selected: selected,
                          onSelected: (v) {
                            _toggleSplitTarget(p, v);
                            setSheetState(() {});
                          },
                        );
                      }).toList(),
                    ),
                    if (!_showAdvancedSplit && settlementPeople.isNotEmpty)
                      if (settlementPeople
                          .every((p) => (_personQtyDraftValues[p] ?? 0) == 0))
                        Padding(
                          padding: const EdgeInsets.only(top: 2, bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  '전원',
                                  style: Theme.of(sheetContext)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        fontSize: 12,
                                        height: 1.2,
                                        color: Theme.of(sheetContext)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '1/N',
                                  style: Theme.of(sheetContext)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                    fontSize: 12,
                                    height: 1.2,
                                    color: Theme.of(sheetContext)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    const SizedBox(height: 8),
                    if (_showAdvancedSplit) ...[
                      Text(
                        '필요한 품목만 사람별 수량을 직접 조절합니다.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(sheetContext)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...settlementPeople.map((p) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 88,
                                child: Text(
                                  p,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(sheetContext)
                                      .textTheme
                                      .bodyMedium,
                                ),
                              ),
                              Expanded(
                                child: _personQtyStepper(
                                  sheetContext,
                                  p,
                                  onChanged: refreshSheet,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ] else
                      Text(
                        '기본은 전원 선택입니다. 정산 대상에서 제외할 사람만 해제하면 됩니다.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(sheetContext)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: 16),
                    FilledButton.tonal(
                      onPressed: () async {
                        saved = await _submitItemDraft();
                        if (saved && sheetContext.mounted) {
                          Navigator.pop(sheetContext);
                        }
                      },
                      child: Text(index == null ? '추가하기' : '수정 반영'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (!saved && mounted) {
      _cancelItemDraftEdit();
    }
  }

  void _cancelItemDraftEdit() {
    setState(() {
      _editingItemIndex = null;
      _clearItemDraftFields();
    });
  }

  Receipt _receiptFromCurrentForm() {
    if (!_canEditCurrentPaymentDetails && widget.receipt != null) {
      return widget.receipt!.copyWith(items: List<ReceiptItem>.from(_items));
    }

    final amount =
        double.tryParse(_amountController.text.replaceAll(',', '')) ?? 0;
    final estimate = _paymentEstimate;
    return Receipt(
      id: widget.receipt?.id ?? _persistedReceiptId ?? '',
      storeName: _storeController.text.trim(),
      amount: amount,
      date: _date,
      category: _category,
      imagePath: _imagePath,
      recognition: _recognition,
      paidBy: _paidBy!,
      currencyCode: _currencyCode,
      paymentMethod: _paymentMethod,
      cardType: _selectedCardProfile?.cardType ??
          widget.receipt?.cardType ??
          'credit',
      cardIssuer: _paymentMethod == paymentMethodCash ||
              _cardIssuerController.text.trim().isEmpty
          ? null
          : _cardIssuerController.text.trim(),
      bankName: _paymentMethod == paymentMethodCash ||
              _bankNameController.text.trim().isEmpty
          ? null
          : _bankNameController.text.trim(),
      cardBrand: _paymentMethod == paymentMethodCash ||
              _cardBrandController.text.trim().isEmpty
          ? null
          : _cardBrandController.text.trim(),
      cardLast4: _paymentMethod == paymentMethodCash ||
              _cardLast4Controller.text.trim().isEmpty
          ? null
          : _cardLast4Controller.text.trim(),
      cardBrandFeeRate: _paymentMethod == paymentMethodCard
          ? estimate.cardBrandFeeRate
          : null,
      cardIssuerFeeRate: _paymentMethod == paymentMethodCard
          ? estimate.cardIssuerFeeRate
          : null,
      issuerFeeType:
          _paymentMethod == paymentMethodCard ? estimate.issuerFeeType : null,
      issuerFeeFixedUsd: _paymentMethod == paymentMethodCard &&
              estimate.issuerFeeType == 'fixed_usd'
          ? estimate.issuerFeeFixedUsd
          : null,
      cashKrwPerUnit: _paymentMethod == paymentMethodCash
          ? _parseCashKrwPerUnit() ?? estimate.cashKrwPerUnit
          : null,
      estimatedKrwAmount: estimate.estimatedKrwAmount,
      actualKrwAmount:
          _paymentMethod == paymentMethodCard ? estimate.actualKrwAmount : null,
      localToUsdRate: estimate.localToUsdRate,
      usdAmount: estimate.usdAmount,
      usdToKrwRate: estimate.usdToKrwRate,
      baseKrwAmount: estimate.baseKrwAmount,
      cardBrandFeeKrw: estimate.cardBrandFeeKrw,
      cardIssuerFeeKrw: estimate.cardIssuerFeeKrw,
      exchangeRateSource: estimate.exchangeRateSource,
      rateDateLabel: estimate.rateDateLabel,
      confidence: _recognitionConfidence,
      warnings: _recognitionWarnings,
      items: List<ReceiptItem>.from(_items),
    );
  }

  Future<bool> _persistReceiptToServer() async {
    return _persistReceiptToServerInternal(showError: true);
  }

  Future<bool> _persistReceiptToServerInternal({
    required bool showError,
  }) async {
    final provider = context.read<TripProvider>();
    final receipt = _receiptFromCurrentForm();
    try {
      if (widget.receipt != null || _persistedReceiptId != null) {
        await provider.updateReceipt(widget.tripId, receipt);
      } else {
        final saved = await provider.addReceipt(widget.tripId, receipt);
        if (saved != null && mounted) {
          setState(() => _persistedReceiptId = saved.id);
        }
      }
      return true;
    } on ApiException catch (e) {
      if (mounted && showError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
      return false;
    }
  }

  Future<bool> _autoSaveReceiptDraft(String reason) async {
    if (!mounted) return false;
    final trip = context.read<TripProvider>().getTrip(widget.tripId);
    if (trip == null) return false;
    if ((_paidBy ?? '').trim().isEmpty) {
      final currentUser = context.read<UserProvider>().currentUser;
      final fallbackName = currentUser?.displayName ?? '';
      if (fallbackName.isEmpty) return false;
      setState(() => _paidBy = fallbackName);
    }

    setState(() {
      _isAutoSaving = true;
      _ocrStatusMessage = '$reason 자동 저장 중입니다.';
    });
    final saved = await _persistReceiptToServerInternal(showError: false);
    if (!mounted) return saved;
    setState(() {
      _isAutoSaving = false;
      _ocrStatusMessage = saved
          ? '$reason 자동 저장되었습니다.'
          : '$reason 자동 저장에 실패했습니다. 저장 버튼을 눌러 주세요.';
    });
    return saved;
  }

  Future<bool> _submitItemDraft() async {
    final trip = context.read<TripProvider>().getTrip(widget.tripId);
    if (trip == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('여행 정보를 불러올 수 없습니다')),
      );
      return false;
    }

    final name = _itemDraftNameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('품목명을 입력하세요')),
      );
      return false;
    }
    final qtyRaw = _itemDraftQtyController.text.replaceAll(',', '').trim();
    final qty = double.tryParse(qtyRaw);
    if (qtyRaw.isEmpty || qty == null || qty <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('수량에 0보다 큰 숫자를 입력하세요')),
      );
      return false;
    }
    final priceRaw = _itemDraftPriceController.text.replaceAll(',', '').trim();
    final unit = double.tryParse(priceRaw);
    if (priceRaw.isEmpty || unit == null || unit < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('단가에 0 이상의 숫자를 입력하세요')),
      );
      return false;
    }

    final totalRaw = _itemDraftTotalController.text.replaceAll(',', '').trim();
    final totalParsed = totalRaw.isEmpty ? null : double.tryParse(totalRaw);
    if (totalRaw.isNotEmpty && (totalParsed == null || totalParsed < 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('총가격에 올바른 숫자를 입력하거나 비우세요')),
      );
      return false;
    }
    final lineTotal = totalParsed ?? (qty * unit);
    final settlementNames = _participantsForItemSettlement(trip);
    final quantityByPerson = _readQuantityByPerson(
      settlementNames,
      splitItemQuantity: qty,
    );
    if (quantityByPerson.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('정산할 참가자 정보가 없습니다. 여행에 참가자를 확인하세요'),
        ),
      );
      return false;
    }

    final existingItem =
        _editingItemIndex == null ? null : _items[_editingItemIndex!];
    final item = ReceiptItem(
      name: name,
      translatedName: existingItem != null && existingItem.name == name
          ? existingItem.translatedName
          : null,
      quantity: qty,
      unitPrice: unit,
      lineTotal: lineTotal,
      quantityByPerson: quantityByPerson,
    );

    setState(() {
      if (_editingItemIndex != null) {
        _items[_editingItemIndex!] = item;
      } else {
        _items.add(item);
      }
      _editingItemIndex = null;
      _clearItemDraftFields();
    });
    return true;
  }

  Future<bool> _pickImage({
    bool recognizeAfterUpload = true,
    bool waitForRecognition = false,
  }) async {
    final api = context.read<ApiService>();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('카메라'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('갤러리'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return false;

    final xFile = await _picker.pickImage(
      source: source,
      imageQuality: 86,
      maxWidth: 1800,
      maxHeight: 2600,
    );
    if (xFile == null) return false;

    final dir = await getApplicationDocumentsDirectory();
    final fileName = 'receipt_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final file = File(path.join(dir.path, fileName));
    await file.writeAsBytes(await xFile.readAsBytes());

    setState(() {
      _imagePath = file.path;
      _isOcrLoading = recognizeAfterUpload;
      _isImageUploading = true;
      _ocrStatusMessage = '사진을 서버에 업로드하고 있습니다.';
    });

    var uploadedOk = false;
    try {
      final uploaded = await api.uploadMedia(file.path, kind: 'receipt');
      if (mounted) {
        setState(() {
          _imagePath = uploaded;
          _isImageUploading = false;
          _ocrStatusMessage = '서버에서 영수증을 인식하고 있습니다.';
        });
      }
      await _autoSaveReceiptDraft('사진');
      if (!mounted) return uploadedOk;
      if (recognizeAfterUpload) {
        setState(() => _ocrStatusMessage = '서버에서 영수증을 인식하고 있습니다.');
      }
      if (recognizeAfterUpload) {
        final recognition = _recognizeCurrentReceiptImage(
          showSnackBar: waitForRecognition,
        );
        if (waitForRecognition) {
          await recognition;
        } else {
          unawaited(recognition);
        }
      }
      uploadedOk = true;
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('사진 업로드 실패: ${e.message}')),
        );
      }
    }
    if (mounted) {
      setState(() {
        if (!recognizeAfterUpload || waitForRecognition) {
          _isOcrLoading = false;
        }
        _isImageUploading = false;
      });
    }
    return uploadedOk;
  }

  void _showReceiptImageViewer() {
    final imagePath = _imagePath;
    if (imagePath == null || imagePath.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: Center(
                  child: imagePath.startsWith('http://') ||
                          imagePath.startsWith('https://')
                      ? Image.network(imagePath, fit: BoxFit.contain)
                      : Image.file(File(imagePath), fit: BoxFit.contain),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: IconButton.filled(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _receiptImagePreview(String imagePath) {
    if (imagePath.startsWith('http://') || imagePath.startsWith('https://')) {
      return Image.network(
        imagePath,
        fit: BoxFit.cover,
        cacheWidth: 1200,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return Image.file(
      File(imagePath),
      fit: BoxFit.cover,
      cacheWidth: 1200,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('영수증 삭제'),
        content: const Text('이 영수증을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              context
                  .read<TripProvider>()
                  .deleteReceipt(widget.tripId, widget.receipt!.id);
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (_canEditCurrentPaymentDetails && !_formKey.currentState!.validate()) {
      return;
    }
    if (_canEditCurrentPaymentDetails && _paidBy == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('결제한 사람을 선택하세요')),
      );
      return;
    }
    if (_hasAmountMismatch) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '영수증 총액과 품목 합계가 맞지 않습니다. 차이 ${formatMoneyLabel(_amountDifference.abs(), _currencyCode)}',
          ),
        ),
      );
      return;
    }

    final saved = await _persistReceiptToServer();
    if (!saved || !mounted) return;
    Navigator.pop(context);
  }
}

class _RecognitionQualityPanel extends StatelessWidget {
  const _RecognitionQualityPanel({
    required this.confidence,
    required this.warnings,
  });

  final double? confidence;
  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final percent =
        confidence == null ? null : (confidence!.clamp(0, 1) * 100).round();
    final hasWarning =
        warnings.isNotEmpty || (confidence != null && confidence! < 0.55);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: hasWarning
            ? colorScheme.errorContainer.withValues(alpha: 0.42)
            : colorScheme.primaryContainer.withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: hasWarning ? colorScheme.error : colorScheme.primary,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  hasWarning
                      ? Icons.warning_amber_rounded
                      : Icons.verified_outlined,
                  size: 18,
                  color: hasWarning ? colorScheme.error : colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  percent == null ? 'AI 인식 검증' : 'AI 인식 신뢰도 $percent%',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
            if (warnings.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...warnings.take(3).map(
                    (warning) => Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '· $warning',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              height: 1.35,
                            ),
                      ),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}
