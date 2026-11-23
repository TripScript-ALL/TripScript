import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/settlement_summary.dart';
import '../models/trip.dart';
import '../providers/user_provider.dart';
import '../services/api_service.dart';
import '../utils/format_money.dart';
import '../utils/settlement_kakao_share.dart';

class SettlementScreen extends StatefulWidget {
  final Trip trip;

  const SettlementScreen({super.key, required this.trip});

  @override
  State<SettlementScreen> createState() => _SettlementScreenState();
}

class _SettlementScreenState extends State<SettlementScreen> {
  late Future<SettlementSummary> _summaryFuture;

  @override
  void initState() {
    super.initState();
    _summaryFuture = _loadSummary();
  }

  Future<SettlementSummary> _loadSummary() {
    final user = context.read<UserProvider>().currentUser;
    if (user == null) {
      return Future.error(ApiException('로그인이 필요합니다.'));
    }
    return context.read<ApiService>().getSettlementSummary(
          user.id,
          widget.trip.id,
        );
  }

  Future<void> _setTransferCompleted(
    String mode,
    SettlementTransfer transfer,
    bool completed,
  ) async {
    final user = context.read<UserProvider>().currentUser;
    if (user == null) {
      throw ApiException('로그인이 필요합니다.');
    }
    await context.read<ApiService>().updateSettlementTransferStatus(
          userId: user.id,
          tripId: widget.trip.id,
          mode: mode,
          from: transfer.from,
          to: transfer.to,
          completed: completed,
        );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SettlementSummary>(
      future: _summaryFuture,
      builder: (context, snapshot) {
        return Scaffold(
          appBar: AppBar(
            title: Text('${widget.trip.name} 정산'),
          ),
          body: Builder(
            builder: (context) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '정산 결과를 불러오지 못했습니다.\n${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }

              final summary = snapshot.data!;
              final balances = summary.balances;
              final results = summary.transfers;
              final colorScheme = Theme.of(context).colorScheme;
              final user = context.watch<UserProvider>().currentUser;
              final currentName = user?.displayName ?? '';
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '참여자별 요약',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          ...balances
                              .map((b) => _BalanceSummaryRow(balance: b)),
                          const SizedBox(height: 12),
                          _SettlementShareActions(
                            text: buildSettlementShareText(
                              widget.trip.name,
                              summary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '여행 전체 정산 내용을 카카오톡이나 문자로 보낼 수 있습니다.',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  ..._consolidatedTransferSections(
                    summary: summary,
                    tripName: widget.trip.name,
                    currentName: currentName,
                    transfers: results,
                    allEmptyMessage: '최종 상계 기준으로 추가로 송금할 금액이 없습니다.',
                    onTransferCompletedChanged: (transfer, completed) =>
                        _setTransferCompleted('net', transfer, completed),
                    detailButton: TextButton(
                      onPressed: () => _openOriginalFlowSheet(
                        context,
                        summary: summary,
                        currentName: currentName,
                      ),
                      child: const Text('세부 내역'),
                    ),
                  ),
                  if (summary.receiptBreakdown.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(
                      '계산 설명',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    ...summary.receiptBreakdown.map(
                      (receipt) => Card(
                        child: ExpansionTile(
                          title: Text(receipt.storeName),
                          subtitle: Text(
                            '${receipt.paidBy} 결제 · ${formatWonLabel(receipt.settlementKrwAmount)} · ${receipt.splitBasis}',
                          ),
                          childrenPadding:
                              const EdgeInsets.fromLTRB(16, 0, 16, 14),
                          children: [
                            ...receipt.participantShares.entries.map(
                              (entry) => Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(entry.key),
                                    Text(formatWonLabel(entry.value)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (summary.calculationNotes.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '정산 기준',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            ...summary.calculationNotes.map(
                              (note) => Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: Text(
                                  '· $note',
                                  style: TextStyle(
                                    color: colorScheme.onSurfaceVariant,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _openOriginalFlowSheet(
    BuildContext context, {
    required SettlementSummary summary,
    required String currentName,
  }) {
    final height = MediaQuery.sizeOf(context).height * 0.88;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return SizedBox(
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '원래 흐름',
                        style: Theme.of(sheetContext).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(sheetContext),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '각 영수증에서 결제자에게 원래 보내야 하는 부담액을 합산한 흐름입니다. '
                  '실제로 여기 나온 송금을 모두 할 필요는 없고, 정산 화면에 보이는 송금 안내만 맞추면 됩니다.',
                  style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: _consolidatedTransferSections(
                    summary: summary,
                    tripName: widget.trip.name,
                    currentName: currentName,
                    transfers: summary.grossTransfers,
                    allEmptyMessage: '원래 흐름에서도 표시할 송금 관계가 없습니다.',
                    onTransferCompletedChanged: (transfer, completed) =>
                        _setTransferCompleted('gross', transfer, completed),
                    detailButton: null,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _TransferDirection { send, receive, others }

List<Widget> _consolidatedTransferSections({
  required SettlementSummary summary,
  required String tripName,
  required String currentName,
  required List<SettlementTransfer> transfers,
  required String allEmptyMessage,
  required Future<void> Function(SettlementTransfer transfer, bool completed)?
      onTransferCompletedChanged,
  Widget? detailButton,
}) {
  final mySend = transfers.where((r) => r.from == currentName).toList();
  final myReceive = transfers.where((r) => r.to == currentName).toList();
  final others = transfers
      .where((r) => r.from != currentName && r.to != currentName)
      .toList();

  if (mySend.isEmpty && myReceive.isEmpty && others.isEmpty) {
    return [
      if (detailButton != null)
        Align(
          alignment: Alignment.centerRight,
          child: detailButton,
        ),
      if (detailButton != null) const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(allEmptyMessage),
        ),
      ),
    ];
  }

  final out = <Widget>[];
  void addGap() {
    if (out.isNotEmpty) {
      out.add(const SizedBox(height: 8));
    }
  }

  if (mySend.isEmpty && detailButton != null) {
    out.add(
      Align(
        alignment: Alignment.centerRight,
        child: detailButton,
      ),
    );
  }

  if (mySend.isNotEmpty) {
    out.add(
      _TransferSection(
        title: '내가 보내야 할 정산',
        emptyText: '내가 보낼 정산이 없습니다.',
        transfers: mySend,
        summary: summary,
        tripName: tripName,
        currentName: currentName,
        direction: _TransferDirection.send,
        onTransferCompletedChanged: onTransferCompletedChanged,
        titleTrailing: detailButton,
      ),
    );
  }
  if (myReceive.isNotEmpty) {
    addGap();
    out.add(
      _TransferSection(
        title: '내가 받아야 할 정산',
        emptyText: '내가 받을 정산이 없습니다.',
        transfers: myReceive,
        summary: summary,
        tripName: tripName,
        currentName: currentName,
        direction: _TransferDirection.receive,
        onTransferCompletedChanged: onTransferCompletedChanged,
      ),
    );
  }
  if (others.isNotEmpty) {
    addGap();
    out.add(
      _TransferSection(
        title: '다른 참여자 사이 정산',
        emptyText: '다른 참여자 사이 정산이 없습니다.',
        transfers: others,
        summary: summary,
        tripName: tripName,
        currentName: currentName,
        direction: _TransferDirection.others,
        onTransferCompletedChanged: onTransferCompletedChanged,
      ),
    );
  }
  return out;
}

class _BalanceSummaryRow extends StatelessWidget {
  final ParticipantSettlementBalance balance;

  const _BalanceSummaryRow({required this.balance});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isPositive = balance.balance > 0;
    final isNegative = balance.balance < 0;
    final fg = isPositive
        ? const Color(0xFF2E7D32)
        : isNegative
            ? const Color(0xFFC62828)
            : scheme.onSurfaceVariant;
    final bg = isPositive
        ? const Color(0xFFE7F5EA)
        : isNegative
            ? const Color(0xFFFFE8E6)
            : scheme.surfaceContainerHighest;
    final label = isPositive
        ? '+${formatWonLabel(balance.balance)}'
        : formatWonLabel(balance.balance);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(balance.name)),
          Text(
            '지출 ${formatWonLabel(balance.paid)}',
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransferSection extends StatelessWidget {
  final String title;
  final String emptyText;
  final List<SettlementTransfer> transfers;
  final SettlementSummary summary;
  final String tripName;
  final String currentName;
  final _TransferDirection direction;
  final Future<void> Function(SettlementTransfer transfer, bool completed)?
      onTransferCompletedChanged;
  final Widget? titleTrailing;

  const _TransferSection({
    required this.title,
    required this.emptyText,
    required this.transfers,
    required this.summary,
    required this.tripName,
    required this.currentName,
    required this.direction,
    required this.onTransferCompletedChanged,
    this.titleTrailing,
  });

  @override
  Widget build(BuildContext context) {
    if (transfers.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(emptyText),
        ),
      );
    }
    final sectionAccount = direction == _TransferDirection.receive
        ? summary.participantAccounts[currentName]
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (titleTrailing != null) titleTrailing!,
          ],
        ),
        if (sectionAccount != null &&
            (sectionAccount.bankName.isNotEmpty ||
                sectionAccount.accountNumber.isNotEmpty)) ...[
          const SizedBox(height: 8),
          Text(
            '정산을 요청할 때 안내할 내 계좌입니다.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          _AccountBox(account: sectionAccount),
        ],
        const SizedBox(height: 10),
        ...transfers.map(
          (transfer) => _TransferDetailCard(
            transfer: transfer,
            summary: summary,
            tripName: tripName,
            direction: direction,
            onCompletedChanged: onTransferCompletedChanged == null
                ? null
                : (completed) =>
                    onTransferCompletedChanged!(transfer, completed),
          ),
        ),
      ],
    );
  }
}

class _TransferDetailCard extends StatefulWidget {
  final SettlementTransfer transfer;
  final SettlementSummary summary;
  final String tripName;
  final _TransferDirection direction;
  final Future<void> Function(bool completed)? onCompletedChanged;

  const _TransferDetailCard({
    required this.transfer,
    required this.summary,
    required this.tripName,
    required this.direction,
    required this.onCompletedChanged,
  });

  @override
  State<_TransferDetailCard> createState() => _TransferDetailCardState();
}

class _TransferDetailCardState extends State<_TransferDetailCard> {
  bool _expanded = false;
  late bool _completed;

  @override
  void initState() {
    super.initState();
    _completed = widget.transfer.completed;
  }

  @override
  void didUpdateWidget(covariant _TransferDetailCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transfer.completed != widget.transfer.completed ||
        oldWidget.transfer.from != widget.transfer.from ||
        oldWidget.transfer.to != widget.transfer.to) {
      _completed = widget.transfer.completed;
    }
  }

  Future<void> _toggleCompleted(bool? value) async {
    final next = value ?? false;
    final previous = _completed;
    setState(() => _completed = next);
    try {
      await widget.onCompletedChanged?.call(next);
    } catch (e) {
      if (!mounted) return;
      setState(() => _completed = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('정산 완료 상태 저장 실패: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final transfer = widget.transfer;
    final direction = widget.direction;
    final account = widget.summary.participantAccounts[transfer.to];
    final receipts = _relatedReceipts();
    final canSendMessage = direction == _TransferDirection.receive;
    final showInlineAccount = direction == _TransferDirection.send &&
        account != null &&
        (account.bankName.isNotEmpty || account.accountNumber.isNotEmpty);

    return Card(
      child: ExpansionTile(
        onExpansionChanged: (value) => setState(() => _expanded = value),
        leading: Checkbox(
          value: _completed,
          onChanged:
              widget.onCompletedChanged == null ? null : _toggleCompleted,
          semanticLabel: '정산 완료 여부',
        ),
        title: Text(
          switch (direction) {
            _TransferDirection.receive => '${transfer.from}에게 받을 금액',
            _TransferDirection.send => '${transfer.to}에게 보낼 금액',
            _TransferDirection.others => '${transfer.from} → ${transfer.to}',
          },
          style: TextStyle(
            decoration: _completed ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: Text(
          '${formatWonLabel(transfer.amount)} · ${_completed ? '정산 완료' : '미정산'}',
        ),
        controlAffinity: ListTileControlAffinity.trailing,
        trailing: AnimatedRotation(
          turns: _expanded ? 0.5 : 0,
          duration: const Duration(milliseconds: 160),
          child: Icon(
            Icons.expand_more,
            color: scheme.onSurfaceVariant,
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: [
          if (showInlineAccount) ...[
            _AccountBox(account: account),
            const SizedBox(height: 10),
          ],
          if (canSendMessage) ...[
            _SettlementShareActions(text: _messageText(account)),
            const SizedBox(height: 12),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '관련 결제',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          const SizedBox(height: 6),
          if (receipts.isEmpty)
            Text(
              '최소 송금 관계로 합산된 결과라 특정 영수증과 1:1로 일치하지 않을 수 있습니다.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            )
          else
            ...receipts.map(
              (receipt) => _ReceiptTraceTile(
                receipt: receipt,
                personName: transfer.from,
              ),
            ),
        ],
      ),
    );
  }

  String _messageText(SettlementAccountInfo? account) {
    final buffer = StringBuffer()
      ..writeln('[TripScript] ${widget.tripName} 정산 요청')
      ..writeln('${widget.transfer.from}님, ${widget.transfer.to}님에게 정산을 보내주세요.')
      ..writeln('정산 금액: ${formatWonLabel(widget.transfer.amount)}');
    if (account != null && account.accountNumber.isNotEmpty) {
      buffer
        ..writeln('')
        ..writeln('입금 계좌: ${account.bankName} ${account.accountNumber}')
        ..writeln('예금주: ${account.accountHolder}');
    }
    buffer.writeln('');
    buffer.writeln('관련 결제는 TripScript 정산 화면에서 확인할 수 있습니다.');
    return buffer.toString();
  }

  List<ReceiptSettlementBreakdown> _relatedReceipts() {
    return widget.summary.receiptBreakdown.where((receipt) {
      if (receipt.paidBy != widget.transfer.to) return false;
      return (receipt.participantShares[widget.transfer.from] ?? 0) > 0;
    }).toList();
  }
}

class _SettlementShareActions extends StatelessWidget {
  final String text;

  const _SettlementShareActions({required this.text});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.chat_rounded),
                label: const Text('카카오톡 전송'),
                onPressed: () => shareSettlementTextViaKakaoTalk(
                  context: context,
                  text: text,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.sms_rounded),
                label: const Text('문자 전송'),
                onPressed: () => shareSettlementTextViaSms(
                  context: context,
                  text: text,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.copy_rounded),
          label: const Text('문구 복사'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('정산 문구를 복사했습니다')),
            );
          },
        ),
      ],
    );
  }
}

class _AccountBox extends StatelessWidget {
  final SettlementAccountInfo account;

  const _AccountBox({required this.account});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        [
          if (account.bankName.isNotEmpty) account.bankName,
          if (account.accountNumber.isNotEmpty) account.accountNumber,
          if (account.accountHolder.isNotEmpty) account.accountHolder,
        ].join(' · '),
      ),
    );
  }
}

class _ReceiptTraceTile extends StatefulWidget {
  final ReceiptSettlementBreakdown receipt;
  final String personName;

  const _ReceiptTraceTile({
    required this.receipt,
    required this.personName,
  });

  @override
  State<_ReceiptTraceTile> createState() => _ReceiptTraceTileState();
}

class _ReceiptTraceTileState extends State<_ReceiptTraceTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final receipt = widget.receipt;
    final personName = widget.personName;
    final scheme = Theme.of(context).colorScheme;
    final share = receipt.participantShares[personName] ?? 0;
    final items = receipt.itemShares
        .where((item) => (item.participantShares[personName] ?? 0) > 0)
        .toList();
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        receipt.storeName,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${receipt.paidBy} 결제',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                Text(
                  formatWonLabel(share),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            if (_expanded && items.isNotEmpty) ...[
              const SizedBox(height: 10),
              ...items.map((item) {
                final itemShare = item.participantShares[personName] ?? 0;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(item.name.isEmpty ? '품목' : item.name),
                      ),
                      Text(formatWonLabel(itemShare)),
                    ],
                  ),
                );
              }),
            ] else if (_expanded) ...[
              const SizedBox(height: 10),
              Text(
                '품목 상세가 없는 영수증입니다.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
            if (items.isNotEmpty) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                label: Text(
                  _expanded ? '품목 접기' : '품목 ${items.length}개 더 보기',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
