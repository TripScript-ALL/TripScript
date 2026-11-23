import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../data/reference_lists.dart';
import '../models/card_profile.dart';
import '../providers/trip_provider.dart';
import '../providers/user_provider.dart';
import '../services/api_service.dart';
import '../services/card_profile_storage.dart';
import '../services/storage_service.dart';
import 'home_screen.dart';

class InitialSetupScreen extends StatefulWidget {
  const InitialSetupScreen({super.key});

  @override
  State<InitialSetupScreen> createState() => _InitialSetupScreenState();
}

class _InitialSetupScreenState extends State<InitialSetupScreen> {
  static const _uuid = Uuid();
  final _formKey = GlobalKey<FormState>();
  final _nicknameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _bankController = TextEditingController();
  final _accountController = TextEditingController();
  final _holderController = TextEditingController();
  final _cardNameController = TextEditingController();
  final _last4Controller = TextEditingController();

  String? _company;
  String? _bcMemberCompany;
  String? _brand;
  String? _bankName;
  String _cardType = 'credit';
  bool _isSaving = false;

  static const _companies = [
    '신한카드',
    'KB국민카드',
    '삼성카드',
    '현대카드',
    '하나카드',
    '우리카드',
    '롯데카드',
    'BC카드',
    'NH농협카드',
    'IBK기업은행(BC)',
    '기타',
  ];

  static const _bcMembers = [
    'BC카드',
    'IBK기업은행(BC)',
    'SC제일은행(BC)',
    'DGB대구은행(BC)',
    'BNK부산은행(BC)',
    'BNK경남은행(BC)',
    'NH농협카드(BC)',
  ];

  static const _brands = [
    'VISA',
    'Mastercard',
    'JCB',
    'AMEX',
    'UnionPay',
    '기타',
  ];

  @override
  void initState() {
    super.initState();
    final user = context.read<UserProvider>().currentUser;
    _nicknameController.text = user?.nickname ?? '';
    _phoneController.text = user?.phoneNumber ?? '';
    _bankName = bankOptions.contains(user?.settlementBankName)
        ? user?.settlementBankName
        : null;
    _bankController.text = user?.settlementBankName ?? '';
    _accountController.text = user?.settlementAccountNumber ?? '';
    _holderController.text =
        user?.settlementAccountHolder ?? user?.displayName ?? '';
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _phoneController.dispose();
    _bankController.dispose();
    _accountController.dispose();
    _holderController.dispose();
    _cardNameController.dispose();
    _last4Controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('초기 설정')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'TripScript에서 보일 이름과 정산 정보를 먼저 맞춰둘게요.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _nicknameController,
              decoration: const InputDecoration(
                labelText: '닉네임',
                hintText: '여행 참여자에게 보일 이름',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '닉네임을 입력하세요' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _phoneController,
              decoration: const InputDecoration(
                labelText: '전화번호',
                hintText: '선택 입력',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 20),
            Text('정산 받을 계좌', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _bankName,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '은행',
                      border: OutlineInputBorder(),
                    ),
                    hint: const Text('은행 선택'),
                    items: bankOptions
                        .map((bank) =>
                            DropdownMenuItem(value: bank, child: Text(bank)))
                        .toList(),
                    onChanged: (v) => setState(() {
                      _bankName = v;
                      _bankController.text = v ?? '';
                    }),
                    validator: (v) => v == null ? '은행을 선택하세요' : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _holderController,
                    decoration: const InputDecoration(
                      labelText: '예금주',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '예금주를 입력하세요' : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _accountController,
              decoration: const InputDecoration(
                labelText: '계좌번호',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '계좌번호를 입력하세요' : null,
            ),
            const SizedBox(height: 20),
            Text('결제 카드', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              '카드는 나중에 카드목록에서 더 추가할 수 있습니다.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'credit', label: Text('신용')),
                ButtonSegment(value: 'check', label: Text('체크')),
              ],
              selected: {_cardType},
              onSelectionChanged: (v) => setState(() => _cardType = v.first),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _company,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '카드사/은행',
                border: OutlineInputBorder(),
              ),
              hint: const Text('카드사/은행 선택'),
              items: _companies
                  .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                  .toList(),
              onChanged: (v) => setState(() {
                _company = v;
                _bcMemberCompany = v == 'BC카드' ? _bcMembers.first : null;
              }),
              validator: (v) => v == null ? '카드사/은행을 선택하세요' : null,
            ),
            if (_company == 'BC카드') ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _bcMemberCompany,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'BC 발급사',
                  border: OutlineInputBorder(),
                ),
                items: _bcMembers
                    .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: (v) => setState(() => _bcMemberCompany = v),
                validator: (v) => v == null ? 'BC 발급사를 선택하세요' : null,
              ),
            ],
            const SizedBox(height: 10),
            TextFormField(
              controller: _cardNameController,
              decoration: const InputDecoration(
                labelText: '카드 상품명',
                hintText: '예: 나라사랑카드',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '카드 상품명을 입력하세요' : null,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _brand,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '브랜드',
                      border: OutlineInputBorder(),
                    ),
                    hint: const Text('국제브랜드 선택'),
                    items: _brands
                        .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                        .toList(),
                    onChanged: (v) => setState(() => _brand = v),
                    validator: (v) => v == null ? '국제브랜드를 선택하세요' : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _last4Controller,
                    maxLength: 4,
                    decoration: const InputDecoration(
                      labelText: '끝 4자리',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _isSaving ? null : _save,
              child: _isSaving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('시작하기'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    try {
      final userProvider = context.read<UserProvider>();
      final api = context.read<ApiService>();
      final tripProvider = context.read<TripProvider>();
      final user = userProvider.currentUser;
      if (user == null) return;
      final phone = _phoneController.text.replaceAll(RegExp(r'\D'), '');
      await userProvider.updateProfile(
        name: user.name,
        phoneNumber: phone,
        nickname: _nicknameController.text.trim(),
        settlementBankName: _bankController.text.trim(),
        settlementAccountNumber: _accountController.text.trim(),
        settlementAccountHolder: _holderController.text.trim(),
      );
      final updated = userProvider.currentUser!;
      final card = CardProfile(
        id: _uuid.v4(),
        name: _cardNameController.text.trim(),
        company: _company == 'BC카드'
            ? (_bcMemberCompany ?? 'BC카드')
            : (_company ?? ''),
        brand: _brand ?? '',
        cardType: _cardType,
        last4: _last4Controller.text.trim().isEmpty
            ? null
            : _last4Controller.text.trim(),
      );
      await api.createCardProfile(updated.id, card);
      await CardProfileStorage().saveCards([card], userId: updated.id);
      await StorageService().saveUserCredentials(
        name: updated.name,
        phone: updated.phoneNumber,
        userId: updated.id,
      );
      tripProvider.setUserId(updated.id);
      await tripProvider.loadTrips();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('초기 설정 저장 실패: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}
