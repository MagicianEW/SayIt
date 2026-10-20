import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 界面里的通用积木。
///
/// 抽出来是为了让 [main.dart] 的 `build` 只剩布局骨架，
/// 视觉细节（圆角、配色、滑块样式）集中在这里改。
///
/// 设计约束（来自实际踩坑）：
/// - **控件区不允许出现外层滚动条**。滑块放在 `SingleChildScrollView` 里时，
///   拖动滑块会跟外层滚动打架，macOS 上还会冒出一条常驻滚动条。
///   所以除输入框和下方的列表外，界面里不再有纵向滚动容器。
/// - 需要滚的地方只有两处：文本输入框（内部滚动）与音频文件列表。

/// 一块带标题的圆角面板。
class SectionPanel extends StatelessWidget {
  const SectionPanel({
    super.key,
    this.icon,
    this.title,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(14, 10, 14, 12),
    this.fill = false,
  });

  final IconData? icon;
  final String? title;

  /// 标题右侧的附加信息（例如「共 12 句」）。
  final Widget? trailing;
  final Widget child;
  final EdgeInsetsGeometry padding;

  /// 面板是否撑满父级给出的高度。
  ///
  /// `false`（默认）时面板贴着内容高度收缩；`true` 时面板撑满，
  /// `child` 里可以放 `Expanded`（列表面板用这个）。
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 15, color: scheme.primary),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    title!,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const Spacer(),
                  if (trailing != null) trailing!,
                ],
              ),
              const SizedBox(height: 8),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// 滑块行：左标签 + 中滑块 + 右数值。
///
/// 数值列宽固定（tabular figures），拖动时数字不跳动。
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.valueText,
    this.icon,
    this.tooltipLabel,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;

  /// 右侧显示的文本；不给就用 `value.toStringAsFixed(2)`。
  final String? valueText;
  final ValueChanged<double> onChanged;
  final IconData? icon;

  /// 按住滑块时浮出的气泡文本；不给就不显示气泡。
  final String? tooltipLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0),
      child: Row(
        children: [
          SizedBox(
            width: 66,
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: scheme.primary,
                inactiveTrackColor: scheme.primary.withValues(alpha: 0.16),
                thumbColor: scheme.primary,
                overlayColor: scheme.primary.withValues(alpha: 0.12),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                label: tooltipLabel,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 58,
            child: Text(
              valueText ?? value.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态提示条。
///
/// 文案可能很长（错误信息里带着服务端的原始返回），所以内部允许纵向滚动，
/// 但高度封顶，避免一条报错把整个界面撑开。
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.message,
    this.isError = false,
  });

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = isError ? scheme.errorContainer : scheme.secondaryContainer;
    final fg = isError ? scheme.onErrorContainer : scheme.onSecondaryContainer;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.info_outline,
            size: 15,
            color: fg,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 96),
              child: SingleChildScrollView(
                // Clamping：不给弹性回弹，滚到头就停。
                physics: const ClampingScrollPhysics(),
                child: SelectableText(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: fg,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 下拉选择器外面套一层统一样式的容器，避免三个下拉看起来像贴上去的。
class StyledDropdown<T> extends StatelessWidget {
  const StyledDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.hint,
    this.width,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final String hint;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final button = DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            hint: Text(
              hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            // 始终用 isExpanded：否则 DropdownButton 按内容撑开，
            // 文字稍长（例：中文(繁体)）就会横向溢出。
            isExpanded: true,
            isDense: true,
            borderRadius: BorderRadius.circular(8),
            items: items,
            onChanged: onChanged,
          ),
        ),
      ),
    );

    if (width == null) return button;
    return SizedBox(width: width, child: button);
  }
}

/// 标题右侧的小圆角标签（例：合成中…）。
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: scheme.onPrimaryContainer),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 列表项：序号 + 文本，当前句高亮。
class SentenceTile extends StatelessWidget {
  const SentenceTile({
    super.key,
    required this.index,
    required this.text,
    required this.isActive,
    required this.onTap,
  });

  final int index;
  final String text;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: isActive
            ? scheme.primaryContainer.withValues(alpha: 0.55)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: isActive
                  ? Border.all(color: scheme.primary.withValues(alpha: 0.7))
                  : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 30,
                  child: Text(
                    '${index + 1}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: isActive ? scheme.primary : scheme.outline,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.45,
                      color: isActive
                          ? scheme.onPrimaryContainer
                          : scheme.onSurface,
                    ),
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

/// 空列表的占位提示。
class EmptyListHint extends StatelessWidget {
  const EmptyListHint({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.library_music_outlined, size: 34, color: scheme.outline),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
        ],
      ),
    );
  }
}
