import 'package:flutter/material.dart';

import 'tokens.dart';
import 'trove_icon.dart';

/// A centered, keyboard-aware modal with one bounded scrolling content region.
/// Feature forms own controllers and commit only after validation succeeds.
Future<T?> showTroveDialog<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  List<Widget> actions = const [],
}) => showDialog<T>(
  context: context,
  builder: (context) =>
      TroveDialog(title: title, actions: actions, child: builder(context)),
);

class TroveDialog extends StatelessWidget {
  const TroveDialog({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
  });
  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    insetPadding: const EdgeInsets.all(16),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(TroveTokens.modalRadius),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const TroveIcon('close', size: 24),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 20),
              for (final action in actions)
                Padding(padding: const EdgeInsets.only(top: 8), child: action),
            ],
          ],
        ),
      ),
    ),
  );
}

class TroveButton extends StatelessWidget {
  const TroveButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.secondary = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool secondary;
  @override
  Widget build(BuildContext context) => secondary
      ? OutlinedButton(
          onPressed: onPressed,
          child: Text(label, textAlign: TextAlign.center),
        )
      : FilledButton(
          onPressed: onPressed,
          child: Text(label, textAlign: TextAlign.center),
        );
}

/// Wrap paired controls into a column on small phones or at enlarged text.
class TroveFormRow extends StatelessWidget {
  const TroveFormRow({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final stack =
          constraints.maxWidth < 280 ||
          MediaQuery.textScalerOf(context).scale(14) > 20;
      if (stack) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: 16),
              children[i],
            ],
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: children[i]),
          ],
        ],
      );
    },
  );
}

/// External label wraps without shrinking or truncating at large text sizes.
class TroveTextField extends StatelessWidget {
  const TroveTextField({
    super.key,
    required this.label,
    this.controller,
    this.initialValue,
    this.validator,
    this.onChanged,
    this.helperText,
    this.keyboardType,
    this.enabled = true,
  });
  final String label;
  final TextEditingController? controller;
  final String? initialValue;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onChanged;
  final String? helperText;
  final TextInputType? keyboardType;
  final bool enabled;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      TextFormField(
        controller: controller,
        initialValue: initialValue,
        validator: validator,
        onChanged: onChanged,
        enabled: enabled,
        keyboardType: keyboardType,
        decoration: InputDecoration(helperText: helperText, hintText: label),
      ),
    ],
  );
}
