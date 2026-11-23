import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../data/reference_lists.dart';
import '../providers/trip_provider.dart';
import '../widgets/country_picker_sheet.dart';
import '../providers/user_provider.dart';
import '../services/api_service.dart';

/// 타일에서 선택 가능한 기본 색상\
///TO DO: 색상 업데이트
final _tileColors = [
  Colors.amber.shade700,
  Colors.teal.shade700,
  Colors.indigo.shade700,
  Colors.orange.shade700,
  Colors.deepPurple.shade700,
  Colors.blueGrey.shade700,
  Colors.brown.shade600,
  Colors.cyan.shade700,
];

class AddTripScreen extends StatefulWidget {
  const AddTripScreen({super.key});

  @override
  State<AddTripScreen> createState() => _AddTripScreenState();
}

class _AddTripScreenState extends State<AddTripScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final List<String> _selectedCountries = [];
  late DateTimeRange _range;
  int? _tileColor;
  String? _coverImagePath;
  bool _isCoverUploading = false;
  bool _isSaving = false;
  final _picker = ImagePicker();

  static int _colorToInt(Color c) {
    final a = (c.a * 255).round() & 0xff;
    final r = (c.r * 255).round() & 0xff;
    final g = (c.g * 255).round() & 0xff;
    final b = (c.b * 255).round() & 0xff;
    return (a << 24) | (r << 16) | (g << 8) | b;
  }

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    _range = DateTimeRange(start: start, end: start);
    WidgetsBinding.instance.addPostFrameCallback((_) => _pickTripRange());
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('새 여행 추가'),
        actions: [
          TextButton(
            onPressed: (_isCoverUploading || _isSaving) ? null : _save,
            child: Text(_isSaving ? '저장 중' : '저장'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '여행 이름',
                hintText: '예: 제주도 여행',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '여행 이름을 입력하세요' : null,
            ),
            const SizedBox(height: 16),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '방문 국가',
                border: OutlineInputBorder(),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_selectedCountries.isEmpty)
                    Text(
                      '국가를 선택하세요',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _selectedCountries.map((name) {
                        final country = countryByName(name);
                        return InputChip(
                          avatar: Text(country?.flag ?? ''),
                          label: Text(name),
                          onDeleted: () => setState(
                            () => _selectedCountries.remove(name),
                          ),
                        );
                      }).toList(),
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _showCountryPicker,
                      icon: const Icon(Icons.search),
                      label: const Text('국가 검색/추가'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              title: const Text('여행 기간'),
              subtitle: Text(_formatRange(_range)),
              trailing: const Icon(Icons.calendar_today),
              onTap: () async {
                await _pickTripRange();
              },
            ),
            const SizedBox(height: 24),
            const Text('타일 모양', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              '목록에서 여행 타일의 배경을 선택하세요 (선택 사항)',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickCoverImage,
                    icon: const Icon(Icons.photo_library, size: 20),
                    label: Text(_coverImagePath != null ? '사진 변경' : '사진으로 채우기'),
                  ),
                ),
                if (_isCoverUploading) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ] else if (_coverImagePath != null) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _imagePreview(_coverImagePath!),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _coverImagePath = null),
                  ),
                ],
              ],
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
          ],
        ),
      ),
    );
  }

  Future<void> _pickCoverImage() async {
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
    if (source == null) return;

    final xFile = await _picker.pickImage(
      source: source,
      imageQuality: 72,
      maxWidth: 1440,
      maxHeight: 1440,
    );
    if (xFile == null) return;

    final dir = await getApplicationDocumentsDirectory();
    final fileName = 'tile_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final file = File(path.join(dir.path, fileName));
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
          SnackBar(content: Text('사진 업로드 실패: ${e.message}. 저장 시 다시 시도합니다.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isCoverUploading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_isCoverUploading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('대표 사진 업로드가 끝난 뒤 저장해 주세요')),
      );
      return;
    }
    final userName =
        context.read<UserProvider>().currentUser?.displayName.trim();
    if (userName == null || userName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('사용자 정보를 먼저 확인하세요')),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final coverImagePath = await _ensureCoverUploaded();
      if (!mounted) return;
      await context.read<TripProvider>().addTrip(
            name: _nameController.text.trim(),
            startDate: _range.start,
            endDate: _range.end,
            participants: [userName],
            hostName: userName,
            countries: _selectedCountries,
            tileColor: _tileColor,
            coverImagePath: coverImagePath,
          );
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('여행 저장 실패: ${e.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _showCountryPicker() async {
    final selected = await showCountryPickerSheet(context);
    if (selected == null || _selectedCountries.contains(selected)) return;
    setState(() => _selectedCountries.add(selected));
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

  String _formatRange(DateTimeRange range) {
    String fmt(DateTime d) =>
        '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
    final start = fmt(range.start);
    final end = fmt(range.end);
    return start == end ? start : '$start ~ $end';
  }

  Future<void> _pickTripRange() async {
    if (!mounted) return;
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _range,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      helpText: '여행 기간 설정',
      saveText: '저장',
      confirmText: '저장',
      cancelText: '취소',
    );
    if (picked != null && mounted) setState(() => _range = picked);
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
