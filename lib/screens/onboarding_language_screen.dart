import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/locale_provider.dart';
import 'conversation_list_screen.dart';

class OnboardingLanguageScreen extends StatefulWidget {
  const OnboardingLanguageScreen({super.key});

  @override
  State<OnboardingLanguageScreen> createState() =>
      _OnboardingLanguageScreenState();
}

class _OnboardingLanguageScreenState extends State<OnboardingLanguageScreen> {
  String? _selectedCode;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Logo
              Expanded(
                flex: 3,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 56,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Nexus',
                      style:
                          Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                    ),
                  ],
                ),
              ),

              // Language selection
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Select Language / 选择语言',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Choose your preferred display language\n请选择你偏好的显示语言',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 24),
                    _LanguageOption(
                      flag: '🇨🇳',
                      title: '简体中文',
                      subtitle: 'Chinese (Simplified)',
                      selected: _selectedCode == 'zh',
                      onTap: () => setState(() => _selectedCode = 'zh'),
                    ),
                    const SizedBox(height: 12),
                    _LanguageOption(
                      flag: '🇺🇸',
                      title: 'English',
                      subtitle: 'English (US)',
                      selected: _selectedCode == 'en',
                      onTap: () => setState(() => _selectedCode = 'en'),
                    ),
                  ],
                ),
              ),

              // Continue button
              Expanded(
                flex: 2,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: _selectedCode == null
                          ? null
                          : () async {
                              final provider = context.read<LocaleProvider>();
                              await provider.setLocale(Locale(_selectedCode!));
                              await provider.completeOnboarding();
                              if (context.mounted) {
                                Navigator.of(context).pushReplacement(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const ConversationListScreen(),
                                  ),
                                );
                              }
                            },
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        _selectedCode == 'zh' ? '继续' : 'Continue',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LanguageOption extends StatelessWidget {
  final String flag;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _LanguageOption({
    required this.flag,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final borderColor =
        selected ? colorScheme.primary : colorScheme.outlineVariant;
    final bgColor = selected
        ? colorScheme.primaryContainer.withValues(alpha: 0.5)
        : Colors.transparent;

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Text(flag, style: const TextStyle(fontSize: 32)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            )),
                  ],
                ),
              ),
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: selected ? colorScheme.primary : colorScheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
