import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:studymate/core/config/env_config.dart';
import 'package:studymate/core/constants/app_colors.dart';
import 'package:studymate/core/constants/app_strings.dart';
import 'package:studymate/core/router/app_router.dart';
import 'package:studymate/core/theme/app_theme.dart';

class StudyMateApp extends ConsumerWidget {
  const StudyMateApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: AppStrings.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      routerConfig: router,
      builder: (context, child) {
        if (!EnvConfig.isSupabaseConfigured) {
          return child ?? const SizedBox.shrink();
        }
        return ColoredBox(
          color: AppColors.primary.withValues(alpha: 0.0),
          child: child,
        );
      },
    );
  }
}
