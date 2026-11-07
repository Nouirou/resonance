import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:resonance/core/utils/uicons.dart';
import 'package:resonance/core/widgets/buttons/resonance_button.dart';
import 'package:resonance/core/widgets/overlays/floating_sheet_shell.dart';

import '../../application/connect_client_notifier.dart';
import '../../domain/models/connect_device.dart';

/// Dialog/Sheet used on Mobile (or Desktop client) to:
/// 1. Enter a 4-digit PIN for a discovered `ConnectDevice`.
/// 2. Manually enter `IP:Port` + 4-digit PIN when UDP/mDNS is blocked by router AP Isolation.
/// 3. Scan a `resonance://connect?...` QR code from Desktop using `MobileScanner`.
class ConnectPinEntryDialog extends ConsumerStatefulWidget {
  final ConnectDevice? targetDevice;
  final bool initialQrMode;

  const ConnectPinEntryDialog({
    super.key,
    this.targetDevice,
    this.initialQrMode = false,
  });

  static Future<bool?> showForDevice(
    BuildContext context,
    ConnectDevice device,
  ) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) => ConnectPinEntryDialog(targetDevice: device),
    );
  }

  static Future<bool?> showManualEntry(
    BuildContext context, {
    bool qrMode = false,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) => ConnectPinEntryDialog(initialQrMode: qrMode),
    );
  }

  @override
  ConsumerState<ConnectPinEntryDialog> createState() =>
      _ConnectPinEntryDialogState();
}

class _ConnectPinEntryDialogState extends ConsumerState<ConnectPinEntryDialog> {
  late final TextEditingController _hostController;
  final TextEditingController _pinController = TextEditingController();
  MobileScannerController? _qrController;
  bool _isQrScanning = false;
  bool _isSubmitting = false;
  String? _localError;

  @override
  void initState() {
    super.initState();
    _isQrScanning = widget.initialQrMode;
    if (_isQrScanning) {
      _qrController = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
      );
    }
    _hostController = TextEditingController(
      text: widget.targetDevice?.endpoint ?? '',
    );
  }

  @override
  void dispose() {
    _qrController?.dispose();
    _hostController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _submitPinOrManual() async {
    final pin = _pinController.text.trim();
    if (pin.length != 4) {
      setState(() => _localError = 'Enter the 4-digit PIN shown on Desktop.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _localError = null;
    });

    bool ok = false;
    final notifier = ref.read(connectClientProvider.notifier);

    if (widget.targetDevice != null) {
      ok = await notifier.connectToDevice(
        widget.targetDevice!,
        pin: pin,
      );
    } else {
      final hostInput = _hostController.text.trim();
      if (hostInput.isEmpty) {
        setState(() {
          _isSubmitting = false;
          _localError =
              'Enter the Desktop IP address (e.g. 192.168.1.15:52026).';
        });
        return;
      }
      ok = await notifier.connectViaManualIp(
        hostAddress: hostInput,
        pin: pin,
      );
    }

    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      final err = ref.read(connectClientProvider).errorMessage;
      setState(() {
        _isSubmitting = false;
        _localError = err ?? 'Unable to pair with host.';
      });
    }
  }

  Future<void> _handleQrCodeDetected(String rawValue) async {
    if (_isSubmitting || !rawValue.startsWith('resonance://connect')) return;
    _qrController?.stop();
    setState(() {
      _isSubmitting = true;
      _localError = null;
    });

    final ok = await ref
        .read(connectClientProvider.notifier)
        .connectViaQrUri(rawValue);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      final err = ref.read(connectClientProvider).errorMessage;
      setState(() {
        _isSubmitting = false;
        _isQrScanning = false;
        _localError = err ?? 'QR pairing failed.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;
    final isTargetDevice = widget.targetDevice != null;

    return FloatingSheetShell(
      maxWidth: 420,
      title: _isQrScanning
          ? 'Scan Desktop QR Code'
          : isTargetDevice
              ? 'Pair with ${widget.targetDevice!.name}'
              : 'Connect Manually',
      icon: _isQrScanning
          ? UIcons.regular.qrcode
          : UIcons.regular.laptop_mobile,
      onClose: () => Navigator.pop(context, false),
      children: [
        if (_isQrScanning) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 250,
              child: MobileScanner(
                controller: _qrController,
                onDetect: (capture) {
                  for (final barcode in capture.barcodes) {
                    final raw = barcode.rawValue;
                    if (raw != null && raw.startsWith('resonance://connect')) {
                      _handleQrCodeDetected(raw);
                      break;
                    }
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          ResonanceButton(
            label: 'Enter IP & PIN Instead',
            icon: UIcons.regular.keyboard,
            style: ResonanceButtonStyle.secondary,
            isFullWidth: true,
            onPressed: () {
              _qrController?.stop();
              setState(() => _isQrScanning = false);
            },
          ),
        ] else ...[
          if (!isTargetDevice) ...[
            Text(
              'HOST IP:PORT',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _hostController,
              keyboardType: TextInputType.url,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                hintText: '192.168.1.10:52026',
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: isDark ? 0.35 : 0.55,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
            ),
            const SizedBox(height: 14),
          ] else ...[
            Text(
              'Enter the 4-digit PIN displayed in Resonance Connect on "${widget.targetDevice!.name}" (${widget.targetDevice!.endpoint}).',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
          ],
          Text(
            '4-DIGIT PAIRING PIN',
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _pinController,
            autofocus: isTargetDevice,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 4,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _submitPinOrManual(),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: 10,
              color: primary,
            ),
            decoration: InputDecoration(
              counterText: '',
              hintText: '0000',
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: isDark ? 0.35 : 0.55,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
            ),
          ),
          if (_localError != null) ...[
            const SizedBox(height: 10),
            Text(
              _localError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 16),
          ResonanceButton(
            label: _isSubmitting ? 'Pairing...' : 'Pair & Connect',
            icon: UIcons.regular.link,
            isFullWidth: true,
            onPressed: _isSubmitting ? null : _submitPinOrManual,
          ),
        ],
      ],
    );
  }
}
