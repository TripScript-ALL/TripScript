import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../data/reference_lists.dart';
import '../models/receipt.dart';
import '../models/trip.dart';
import '../models/user.dart';
import '../providers/trip_provider.dart';
import '../providers/user_provider.dart';
import '../services/api_service.dart';
import '../utils/exchange_rates.dart';
import '../utils/format_money.dart';
import '../utils/payment_estimator.dart';
import '../widgets/country_picker_sheet.dart';
import '../widgets/trip_hero_tile_content.dart';
import '../widgets/trip_hero_tile_shuttle.dart';
import '../widgets/trip_spending_charts.dart';
import 'add_receipt_screen.dart';
import 'settlement_screen.dart';

class TripDetailScreen extends StatefulWidget {
  final String tripId;
  final String? heroTag;

  const TripDetailScreen({super.key, required this.tripId, this.heroTag});

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await context.read<TripProvider>().loadReceiptsForTrip(widget.tripId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Consumer<TripProvider>(
          builder: (context, provider, _) {
            final trip = provider.getTrip(widget.tripId);
            if (trip == null) return const Text('여행 상세');
            return _FadingTripName(trip: trip);
          },
        ),
        actions: [
          Consumer2<TripProvider, UserProvider>(
            builder: (context, tripProvider, userProvider, _) {
              final trip = tripProvider.getTrip(widget.tripId);
              final user = userProvider.currentUser;
              if (trip == null || user == null) {
                return const SizedBox.shrink();
              }
              final isHost = user.matchesParticipantName(trip.hostName);
              return IconButton(
                icon: Icon(isHost ? Icons.delete_outline : Icons.exit_to_app),
                onPressed: () => isHost
                    ? _confirmDelete(context)
                    : _confirmLeave(context, user),
              );
            },
          ),
        ],
      ),
      body: Consumer<TripProvider>(
        builder: (context, provider, _) {
          final trip = provider.getTrip(widget.tripId);
          if (trip == null) {
            return const Center(child: Text('여행을 찾을 수 없습니다'));
          }
          final user = context.watch<UserProvider>().currentUser;
          final isTripHostView =
              user != null && user.matchesParticipantName(trip.hostName);
          return _TripDetailBody(
            trip: trip,
            isTripHostView: isTripHostView,
            heroTag: widget.heroTag,
            onAddReceipt: () {
              Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => AddReceiptScreen(tripId: widget.tripId),
                ),
              );
            },
          );
        },
      ),
      bottomNavigationBar: Consumer<TripProvider>(
        builder: (context, provider, _) {
          final trip = provider.getTrip(widget.tripId);
          if (trip == null) return const SizedBox.shrink();
          return _TripBottomSettlementBar(
            trip: trip,
            onSettlement: trip.receipts.isEmpty
                ? null
                : () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => SettlementScreen(trip: trip),
                      ),
                    );
                  },
          );
        },
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('여행 삭제'),
        content: const Text('이 여행과 모든 영수증을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              context.read<TripProvider>().deleteTrip(widget.tripId);
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

  void _confirmLeave(BuildContext context, User user) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('여행 나가기'),
        content: const Text('이 여행에서 나가시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () async {
              await context.read<TripProvider>().leaveTrip(widget.tripId, user);
              if (!context.mounted) return;
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text('나가기'),
          ),
        ],
      ),
    );
  }
}

void _showEditTileSheet(BuildContext context, Trip trip) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _EditTileSheet(trip: trip),
  );
}

Future<void> _editTripPeriod(BuildContext context, Trip trip) async {
  final range = await showDateRangePicker(
    context: context,
    firstDate: DateTime(2020),
    lastDate: DateTime(2030),
    initialDateRange: DateTimeRange(
      start: DateTime(
          trip.startDate.year, trip.startDate.month, trip.startDate.day),
      end: DateTime(trip.endDate.year, trip.endDate.month, trip.endDate.day),
    ),
    initialEntryMode: DatePickerEntryMode.calendar,
    helpText: '기간 설정',
    saveText: '저장',
    confirmText: '저장',
    cancelText: '취소',
  );
  if (range == null || !context.mounted) return;

  final start = DateTime(range.start.year, range.start.month, range.start.day);
  final end = DateTime(range.end.year, range.end.month, range.end.day);

  try {
    await context.read<TripProvider>().updateTrip(
          trip.copyWith(startDate: start, endDate: end),
        );
  } on ApiException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }
}

Future<void> _editTripCountries(BuildContext context, Trip trip) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetCtx) => _EditCountriesSheet(trip: trip),
  );
}

class _EditCountriesSheet extends StatefulWidget {
  final Trip trip;

  const _EditCountriesSheet({required this.trip});

  @override
  State<_EditCountriesSheet> createState() => _EditCountriesSheetState();
}

class _EditCountriesSheetState extends State<_EditCountriesSheet> {
  late List<String> _countries;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _countries = List<String>.from(widget.trip.countries);
  }

  Future<void> _pickCountry() async {
    final selected = await showCountryPickerSheet(context);
    if (selected == null || !mounted || _countries.contains(selected)) return;
    setState(() => _countries.add(selected));
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      await context.read<TripProvider>().updateTrip(
            widget.trip.copyWith(countries: List<String>.from(_countries)),
          );
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.88;
    final cs = Theme.of(context).colorScheme;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.paddingOf(context).bottom + 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '방문 국가',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip: '닫기',
                    onPressed: _isSaving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_countries.isEmpty)
                Text(
                  '국가가 없습니다. 검색으로 추가할 수 있습니다.',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _countries.map((name) {
                    final country = countryByName(name);
                    return InputChip(
                      avatar: Text(country?.flag ?? ''),
                      label: Text(name),
                      onDeleted: _isSaving
                          ? null
                          : () => setState(() => _countries.remove(name)),
                    );
                  }).toList(),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _isSaving ? null : _pickCountry,
                icon: const Icon(Icons.search),
                label: const Text('국가 검색/추가'),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _isSaving ? null : _save,
                child: Text(_isSaving ? '저장 중' : '저장'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditTileSheet extends StatefulWidget {
  final Trip trip;

  const _EditTileSheet({required this.trip});

  @override
  State<_EditTileSheet> createState() => _EditTileSheetState();
}

class _EditTileSheetState extends State<_EditTileSheet> {
  static int _colorToInt(Color c) {
    final a = (c.a * 255).round() & 0xff;
    final r = (c.r * 255).round() & 0xff;
    final g = (c.g * 255).round() & 0xff;
    final b = (c.b * 255).round() & 0xff;
    return (a << 24) | (r << 16) | (g << 8) | b;
  }

  static final _tileColors = [
    Colors.amber.shade700,
    Colors.teal.shade700,
    Colors.indigo.shade700,
    Colors.orange.shade700,
    Colors.deepPurple.shade700,
    Colors.blueGrey.shade700,
    Colors.brown.shade600,
    Colors.cyan.shade700,
  ];

  late int? _tileColor;
  late String? _coverImagePath;
  bool _isCoverUploading = false;
  bool _isSaving = false;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _tileColor = widget.trip.tileColor;
    _coverImagePath = widget.trip.coverImagePath;
  }

  Future<void> _pickCoverImage() async {
    final api = context.read<ApiService>();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('카메라'),
              onTap: () => Navigator.pop(sheetCtx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('갤러리'),
              onTap: () => Navigator.pop(sheetCtx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final xFile = await _picker.pickImage(
      source: source,
      imageQuality: 72,
      maxWidth: 1440,
      maxHeight: 1440,
    );
    if (xFile == null) return;

    final dir = await getApplicationDocumentsDirectory();
    final file = File(path.join(
      dir.path,
      'tile_${DateTime.now().millisecondsSinceEpoch}.jpg',
    ));
    await file.writeAsBytes(await xFile.readAsBytes());

    setState(() {
      _coverImagePath = file.path;
      _tileColor = null;
      _isCoverUploading = true;
    });

    try {
      final uploaded = await api.uploadMedia(file.path, kind: 'trip_cover');
      if (mounted) setState(() => _coverImagePath = uploaded);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('사진 업로드 실패: ${e.message}. 적용 시 다시 시도합니다.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isCoverUploading = false);
    }
  }

  Future<void> _apply() async {
    if (_isCoverUploading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('대표 사진 업로드가 끝난 뒤 적용해 주세요')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final coverImagePath = await _ensureCoverUploaded();
      if (!mounted) return;
      await context.read<TripProvider>().updateTrip(
            widget.trip.copyWith(
              tileColor: _tileColor,
              coverImagePath: coverImagePath,
              clearTileColor: _tileColor == null,
              clearCoverImagePath: coverImagePath == null,
            ),
          );
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('여행 수정 실패: ${e.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<String?> _ensureCoverUploaded() async {
    final current = _coverImagePath;
    if (current == null || _isRemoteImagePath(current)) return current;

    final uploaded = await context.read<ApiService>().uploadMedia(
          current,
          kind: 'trip_cover',
        );
    if (mounted) setState(() => _coverImagePath = uploaded);
    return uploaded;
  }

  bool _isRemoteImagePath(String value) {
    return value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.startsWith('/api/v1/media/');
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.88;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.paddingOf(context).bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '타일 모양',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              if (_coverImagePath != null) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _imagePreview(_coverImagePath!),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Material(
                            color: Colors.black.withValues(alpha: 0.45),
                            shape: const CircleBorder(),
                            clipBehavior: Clip.antiAlias,
                            child: IconButton(
                              icon: const Icon(Icons.close, size: 20),
                              color: Colors.white,
                              tooltip: '사진 제거',
                              onPressed: () =>
                                  setState(() => _coverImagePath = null),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _isCoverUploading ? null : _pickCoverImage,
                icon: _isCoverUploading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.photo_library, size: 20),
                label: Text(
                  _isCoverUploading
                      ? '업로드 중'
                      : _coverImagePath != null
                          ? '사진 변경'
                          : '사진으로 채우기',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('기본'),
                    selected: _tileColor == null && _coverImagePath == null,
                    onSelected: (_) => setState(() {
                      _tileColor = null;
                      _coverImagePath = null;
                    }),
                  ),
                  ..._tileColors.map((c) {
                    final value = _colorToInt(c);
                    final selected =
                        _tileColor == value && _coverImagePath == null;
                    return ChoiceChip(
                      avatar: CircleAvatar(backgroundColor: c, radius: 12),
                      label: const Text(''),
                      selected: selected,
                      onSelected: (_) => setState(() {
                        _tileColor = value;
                        _coverImagePath = null;
                      }),
                    );
                  }),
                ],
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: (_isCoverUploading || _isSaving) ? null : _apply,
                child: Text(_isSaving ? '적용 중' : '적용'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _imagePreview(String imagePath) {
    if (imagePath.startsWith('http://') || imagePath.startsWith('https://')) {
      return Image.network(
        imagePath,
        fit: BoxFit.cover,
        cacheWidth: 900,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return Image.file(
      File(imagePath),
      fit: BoxFit.cover,
      cacheWidth: 900,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }
}

enum _ReceiptSortMode { added, date, amount }

class _TripDetailBody extends StatefulWidget {
  final Trip trip;
  final bool isTripHostView;
  final String? heroTag;
  final VoidCallback onAddReceipt;

  const _TripDetailBody({
    required this.trip,
    required this.isTripHostView,
    required this.onAddReceipt,
    this.heroTag,
  });

  @override
  State<_TripDetailBody> createState() => _TripDetailBodyState();
}

class _TripDetailBodyState extends State<_TripDetailBody> {
  static const double _sectionGap = 12;

  _ReceiptSortMode _sortMode = _ReceiptSortMode.added;

  List<Receipt> get _sortedReceipts {
    final receipts = List<Receipt>.from(widget.trip.receipts);
    switch (_sortMode) {
      case _ReceiptSortMode.date:
        receipts.sort((a, b) => b.date.compareTo(a.date));
        break;
      case _ReceiptSortMode.amount:
        receipts.sort(
          (a, b) => estimateReceiptPayment(b)
              .settlementKrwAmount
              .compareTo(estimateReceiptPayment(a).settlementKrwAmount),
        );
        break;
      case _ReceiptSortMode.added:
        break;
    }
    return receipts;
  }

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final isHost = widget.isTripHostView;
    final receipts = _sortedReceipts;

    return RefreshIndicator(
      onRefresh: () async {
        final p = context.read<TripProvider>();
        await p.loadTrips();
        await p.loadReceiptsForTrip(trip.id);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 112),
        children: [
        _TripHeroHeader(trip: trip, heroTag: widget.heroTag, canEdit: isHost),
        const SizedBox(height: _sectionGap),
        _TripSectionCard(
          onTap: isHost ? () => _editTripPeriod(context, trip) : null,
          trailing: isHost
              ? Icon(
                  Icons.edit_calendar_outlined,
                  color: Theme.of(context).colorScheme.primary,
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _TripSectionTitle('여행 기간'),
              const SizedBox(height: 8),
              Text(Trip.formatDateRange(trip.startDate, trip.endDate)),
            ],
          ),
        ),
        const SizedBox(height: _sectionGap),
        _TripSectionCard(
          onTap: isHost ? () => _editTripCountries(context, trip) : null,
          trailing: isHost
              ? Icon(
                  Icons.public_outlined,
                  color: Theme.of(context).colorScheme.primary,
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _TripSectionTitle('방문 국가'),
              const SizedBox(height: 8),
              if (trip.countries.isEmpty)
                Text(
                  isHost
                      ? '국가가 없습니다. 카드를 눌러 추가하세요.'
                      : '등록된 방문 국가가 없습니다.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: trip.countries.map((name) {
                    final country = countryByName(name);
                    return Chip(
                      avatar: Text(country?.flag ?? ''),
                      label: Text(name),
                      visualDensity: VisualDensity.compact,
                    );
                  }).toList(),
                ),
            ],
          ),
        ),
        const SizedBox(height: _sectionGap),
        _ParticipantsCard(
          trip: trip,
          isTripHostView: widget.isTripHostView,
        ),
        const SizedBox(height: _sectionGap),
        TripSpendingCharts(trip: trip),
        const SizedBox(height: _sectionGap),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '영수증 (${trip.receipts.length}건)',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _DashedAddReceiptRow(onTap: widget.onAddReceipt),
        const SizedBox(height: 8),
        if (trip.receipts.length > 1) ...[
          SegmentedButton<_ReceiptSortMode>(
            segments: const [
              ButtonSegment(
                value: _ReceiptSortMode.added,
                icon: Icon(Icons.schedule_outlined),
                label: Text('추가순'),
              ),
              ButtonSegment(
                value: _ReceiptSortMode.date,
                icon: Icon(Icons.event_outlined),
                label: Text('날짜순'),
              ),
              ButtonSegment(
                value: _ReceiptSortMode.amount,
                icon: Icon(Icons.payments_outlined),
                label: Text('금액순'),
              ),
            ],
            selected: {_sortMode},
            onSelectionChanged: (values) =>
                setState(() => _sortMode = values.first),
          ),
          const SizedBox(height: 8),
        ],
        if (trip.receipts.isNotEmpty)
          ...receipts.map((r) => _ReceiptTile(
                receipt: r,
                tripId: trip.id,
              )),
        ],
      ),
    );
  }
}

class _ParticipantsCard extends StatefulWidget {
  final Trip trip;
  final bool isTripHostView;

  const _ParticipantsCard({
    required this.trip,
    required this.isTripHostView,
  });

  @override
  State<_ParticipantsCard> createState() => _ParticipantsCardState();
}

class _ParticipantsCardState extends State<_ParticipantsCard> {
  final _controller = TextEditingController();
  bool _expanded = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isHost => widget.isTripHostView;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.groups_outlined,
                        size: 22,
                        color: cs.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '참여자',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: cs.onSurface,
                                ),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _expanded
                              ? const SizedBox.shrink()
                              : Text(
                                  '${widget.trip.participants.length}명',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: cs.onSurfaceVariant,
                                        height: 1.35,
                                      ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _expanded ? '간단히' : '자세히',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: cs.primary,
                            ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        color: cs.primary,
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
                child: _expanded
                    ? Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: widget.trip.participants.map((name) {
                                final isHost = name == widget.trip.hostName;
                                final canRemove = _isHost && !isHost;
                                // InputChip은 onDeleted 없을 때 M3 기본 채색이 더 흐리게 나옵니다.
                                // Chip으로 통일하면 호스트/참여자에게 동일한 대비가 유지됩니다(X는 canRemove 때만).
                                final hostBorderBright = Brightness.dark ==
                                        Theme.of(context).brightness
                                    ? Colors.amber.shade300
                                    : Colors.amber.shade800;
                                return Chip(
                                  avatar: Icon(
                                    isHost
                                        ? Icons.workspace_premium_outlined
                                        : Icons.person_outline,
                                    size: 18,
                                    color: isHost
                                        ? hostBorderBright
                                            .withValues(alpha: 0.95)
                                        : null,
                                  ),
                                  label: Text(isHost ? '$name · 대표' : name),
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  surfaceTintColor: Colors.transparent,
                                  shape: StadiumBorder(
                                    side: BorderSide(
                                      color: isHost
                                          ? hostBorderBright
                                              .withValues(alpha: 0.92)
                                          : cs.outlineVariant
                                              .withValues(alpha: 0.72),
                                      width: isHost ? 2 : 1,
                                    ),
                                  ),
                                  onDeleted: canRemove
                                      ? () => _removeParticipant(
                                            context,
                                            name,
                                          )
                                      : null,
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: SelectableText(
                                    '초대 코드 '
                                    '${widget.trip.inviteCode}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '초대 코드 복사',
                                  onPressed: () {
                                    Clipboard.setData(
                                      ClipboardData(
                                        text: widget.trip.inviteCode,
                                      ),
                                    );
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          '초대 코드가 복사되었습니다',
                                        ),
                                      ),
                                    );
                                  },
                                  icon: const Icon(Icons.copy),
                                ),
                              ],
                            ),
                            if (_isHost) ...[
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _controller,
                                      decoration: const InputDecoration(
                                        labelText: '참여자 이름',
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                      ),
                                      onSubmitted: (_) =>
                                          _addParticipant(context),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton.filled(
                                    tooltip: '참여자 추가',
                                    onPressed: () => _addParticipant(context),
                                    icon: const Icon(Icons.add),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addParticipant(BuildContext context) async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    try {
      await context.read<TripProvider>().addParticipant(widget.trip.id, name);
      _controller.clear();
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _removeParticipant(BuildContext context, String name) async {
    try {
      await context
          .read<TripProvider>()
          .removeParticipant(widget.trip.id, name);
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _TripSectionTitle extends StatelessWidget {
  final String text;

  const _TripSectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
    );
  }
}

class _TripSectionCard extends StatelessWidget {
  final Widget child;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _TripSectionCard({
    required this.child,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: trailing == null
          ? child
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: child),
                const SizedBox(width: 12),
                trailing!,
              ],
            ),
    );

    return Card(
      child: onTap == null
          ? content
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: content,
            ),
    );
  }
}

class _TripBottomSettlementBar extends StatelessWidget {
  final Trip trip;
  final VoidCallback? onSettlement;

  const _TripBottomSettlementBar({
    required this.trip,
    required this.onSettlement,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final totalKrw = tripTotalInKrw(trip);
    final totals = tripTotalsByCurrency(trip);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(text: '총 지출: '),
                            TextSpan(text: formatWonLabel(totalKrw)),
                          ],
                        ),
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (totals.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          children: totals.entries
                              .map(
                                (entry) => _CurrencyTotalPill(
                                  label:
                                      formatMoneyLabel(entry.value, entry.key),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: onSettlement,
                  icon: const Icon(Icons.account_balance_wallet_outlined),
                  label: const Text('정산하기'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CurrencyTotalPill extends StatelessWidget {
  final String label;

  const _CurrencyTotalPill({required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.65)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                height: 1.05,
              ),
        ),
      ),
    );
  }
}

/// 점선 테두리 안에 영수증 추가 유도
class _DashedRoundedRectPainter extends CustomPainter {
  _DashedRoundedRectPainter({
    required this.color,
    this.borderRadius = 12,
  });

  final Color color;
  final double borderRadius;

  static const double _strokeWidth = 1.5;
  static const double _dashWidth = 6;
  static const double _gapWidth = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      _strokeWidth / 2,
      _strokeWidth / 2,
      size.width - _strokeWidth,
      size.height - _strokeWidth,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius));
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth;

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + _dashWidth).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + _gapWidth;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRoundedRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.borderRadius != borderRadius;
}

class _DashedAddReceiptRow extends StatelessWidget {
  final VoidCallback onTap;

  const _DashedAddReceiptRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: CustomPaint(
          painter: _DashedRoundedRectPainter(
            color: cs.outlineVariant.withValues(alpha: 0.9),
            borderRadius: 12,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.post_add, size: 22, color: cs.primary),
                const SizedBox(width: 8),
                Text(
                  '영수증 추가하기',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FadingTripName extends StatelessWidget {
  final Trip trip;

  const _FadingTripName({required this.trip});

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final animation = route?.animation;

    final opacityAnim = animation == null
        ? const AlwaysStoppedAnimation(1.0)
        : CurvedAnimation(
            parent: animation,
            curve: const Interval(0.6, 1.0, curve: Curves.easeOut),
          );

    final headlineSmall = Theme.of(context).textTheme.headlineSmall;
    final baseSize = headlineSmall?.fontSize ?? 20;

    return FadeTransition(
      opacity: opacityAnim,
      child: Text(
        trip.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: (headlineSmall ?? const TextStyle()).copyWith(
          fontSize: baseSize - 4,
        ),
      ),
    );
  }
}

class _TripHeroHeader extends StatelessWidget {
  final Trip trip;
  final String? heroTag;
  final bool canEdit;

  const _TripHeroHeader({
    required this.trip,
    required this.heroTag,
    required this.canEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Hero(
          tag: heroTag ?? 'trip_tile_${trip.id}',
          placeholderBuilder: (context, size, child) {
            // 전환 중 레이아웃 스냅 방지를 위해 투명 placeholder 유지
            return Opacity(opacity: 0, child: child);
          },
          flightShuttleBuilder: (
            flightContext,
            animation,
            flightDirection,
            fromHeroContext,
            toHeroContext,
          ) {
            return TripHeroTileShuttle(
              trip: trip,
              animation: animation,
              flightDirection: flightDirection,
              showText: false,
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 180,
              child: TripHeroTileContent(trip: trip, t: 1.0, showText: false),
            ),
          ),
        ),
        if (canEdit)
          Positioned(
            top: 2,
            right: 2,
            child: IconButton(
              tooltip: '타일 모양',
              icon: const Icon(Icons.edit_outlined, size: 20),
              color: Colors.white,
              style: IconButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
              ),
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(
                minWidth: 40,
                minHeight: 40,
              ),
              onPressed: () => _showEditTileSheet(context, trip),
            ),
          ),
      ],
    );
  }
}

class _ReceiptTile extends StatefulWidget {
  final Receipt receipt;
  final String tripId;

  const _ReceiptTile({required this.receipt, required this.tripId});

  @override
  State<_ReceiptTile> createState() => _ReceiptTileState();
}

class _ReceiptTileState extends State<_ReceiptTile> {
  bool _expanded = false;

  Widget? _leading(BuildContext context) {
    final img = widget.receipt.imagePath;
    if (img == null || img.isEmpty) {
      return CircleAvatar(
        child: Icon(
          _categoryIcon(widget.receipt.category),
          color: Colors.white,
        ),
      );
    }
    if (img.startsWith('http://') || img.startsWith('https://')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          img,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          cacheWidth: 96,
          cacheHeight: 96,
          errorBuilder: (_, __, ___) => CircleAvatar(
            child: Icon(
              _categoryIcon(widget.receipt.category),
              color: Colors.white,
            ),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        File(img),
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        cacheWidth: 96,
        cacheHeight: 96,
        errorBuilder: (_, __, ___) => CircleAvatar(
          child: Icon(
            _categoryIcon(widget.receipt.category),
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final receipt = widget.receipt;
    final variant = Theme.of(context).colorScheme.onSurfaceVariant;
    final estimate = estimateReceiptPayment(receipt);
    final methodLabel =
        estimate.paymentMethod == paymentMethodCash ? '현금' : '카드';
    final visibleItems =
        _expanded ? receipt.items : receipt.items.take(5).toList();
    final hiddenCount = receipt.items.length - visibleItems.length;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _editReceipt(context),
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: _leading(context),
              title: Text(receipt.storeName),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${receipt.paidBy} · ${receipt.category}'
                    ' · $methodLabel'
                    '${receipt.items.isNotEmpty ? ' · 품목 ${receipt.items.length}개' : ''}',
                    style: TextStyle(fontSize: 12, color: variant),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatDateTime(receipt.date),
                    style: TextStyle(fontSize: 11, color: variant),
                  ),
                ],
              ),
              trailing: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatMoneyLabel(receipt.amount, receipt.currencyCode),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ) ??
                        const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (receipt.currencyCode != 'KRW')
                    Text(
                      formatWonLabel(estimate.settlementKrwAmount),
                      style: TextStyle(fontSize: 12, color: variant),
                    ),
                ],
              ),
            ),
            if (receipt.items.isNotEmpty) ...[
              Divider(height: 1, color: Theme.of(context).dividerColor),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: List.generate(visibleItems.length, (i) {
                    final item = visibleItems[i];
                    final qtyLabel = item.quantity % 1 == 0
                        ? item.quantity.toStringAsFixed(0)
                        : item.quantity.toString();
                    final sub = item.quantity > 0 || item.unitPrice > 0
                        ? '${formatMoneyLabel(item.unitPrice, receipt.currencyCode)} × $qtyLabel'
                        : null;
                    return Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name.isEmpty ? '(이름 없음)' : item.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                if (sub != null)
                                  Text(
                                    sub,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: variant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Text(
                            formatMoneyLabel(
                              item.lineTotal,
                              receipt.currencyCode,
                            ),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
              ),
              if (hiddenCount > 0 || _expanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: OutlinedButton.icon(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    icon:
                        Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                    label: Text(
                      _expanded ? '품목 접기' : '품목 $hiddenCount개 더 보기',
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime date) {
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  IconData _categoryIcon(String category) {
    switch (category) {
      case '식비':
        return Icons.restaurant;
      case '교통':
        return Icons.directions_car;
      case '숙박':
        return Icons.hotel;
      case '쇼핑':
        return Icons.shopping_bag;
      default:
        return Icons.receipt;
    }
  }

  void _editReceipt(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddReceiptScreen(
          tripId: widget.tripId,
          receipt: widget.receipt,
        ),
      ),
    );
  }
}
