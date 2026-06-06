import "package:flutter/material.dart";

class ScreenSplitter extends StatefulWidget {
  final Widget childA;
  final Widget? childB; // 可选参数
  
  // 新增：默认展开比例和最大比例
  final double defaultSplit;
  final double maxSplit;

  const ScreenSplitter({
    super.key,
    required this.childA,
    this.childB,
    this.defaultSplit = 0.3, // 默认值为目前的硬编码值
    this.maxSplit = 0.5,     // 默认值为目前的硬编码值
  });

  @override
  State<ScreenSplitter> createState() => _ScreenSplitterState();
}

// 1. 引入 SingleTickerProviderStateMixin 提供 Vsync 供动画使用
class _ScreenSplitterState extends State<ScreenSplitter>
    with SingleTickerProviderStateMixin {
  
  // 2. 将普通的 double 替换为 AnimationController
  late AnimationController _controller;
  // 移除了原先的 final double _maxSplit = 0.5; 改用 widget.maxSplit

  @override
  void initState() {
    super.initState();
    
    // 初始化 AnimationController，默认值为 0.0 (收起状态)
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 0.0, 
    );

    // 监听动画值改变以触发重绘
    _controller.addListener(() {
      setState(() {});
    });

    // 场景1：组件初始化时，如果 childB 不为空，执行展开动画
    if (widget.childB != null) {
      _controller.animateTo(widget.defaultSplit, curve: Curves.easeOut);
    }
  }

  @override
  void didUpdateWidget(ScreenSplitter oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // 场景1补充：如果在运行过程中，childB 被动态传入 (从 null 变为非 null)
    // 强制把进度设回 0，然后开始展开动画
    if (oldWidget.childB == null && widget.childB != null) {
      _controller.value = 0.0;
      _controller.animateTo(widget.defaultSplit, curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    // 必须销毁控制器，防止内存泄漏
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 如果 childB 为 null，直接返回带 Padding 和 SafeArea 的 childA
    if (widget.childB == null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            child: widget.childA,
          ),
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxHeight = constraints.maxHeight;
            final maxWidth = constraints.maxWidth;
            final isLandscape = maxWidth > maxHeight;
            
            // 动态计算点击展开/收起的阈值（原先硬编码的 0.15 就是 0.3 的一半）
            final toggleThreshold = widget.defaultSplit / 2;

            if (isLandscape) {
              // --- 横向布局 ---
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 左侧：占剩余空间
                  Expanded(
                    child: Card(
                      color: Theme.of(context).colorScheme.surfaceContainerLowest,
                      child: widget.childA,
                    ),
                  ),
                  // 拖拽把手（垂直条）
                  GestureDetector(
                    onHorizontalDragUpdate: (details) {
                      // 拖拽时：直接设置 _controller.value，不需要动画，实现跟手拖拽
                      double newValue = _controller.value - (details.delta.dx / maxWidth);
                      _controller.value = newValue.clamp(0.0, widget.maxSplit);
                    },
                    onTap: () {
                      // 场景2：点击时，判断目标值并执行过渡动画
                      double target = _controller.value < toggleThreshold ? widget.defaultSplit : 0.0;
                      _controller.animateTo(target, curve: Curves.easeOut);
                    },
                    child: Container(
                      width: 20,
                      color: Theme.of(context).colorScheme.surface,
                      child: const Center(
                        child: RotatedBox(
                          quarterTurns: 1,
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
                    ),
                  ),
                  // 右侧：宽度根据比例
                  SizedBox(
                    width: maxWidth * _controller.value,
                    // 加入 ClipRect，防止宽度趋近于 0 的动画过程中内部组件溢出(Overflow)报错
                    child: ClipRect(
                      child: Card(
                        color: Theme.of(context).colorScheme.surfaceContainerLowest,
                        child: widget.childB!,
                      ), 
                    ),
                  ),
                ],
              );
            } else {
              // --- 纵向布局 ---
              return Column(
                children: [
                  // 上部：高度根据比例
                  SizedBox(
                    height: maxHeight * _controller.value,
                    // 加入 ClipRect，防止高度趋近于 0 时内部内容溢出
                    child: ClipRect(
                      child: Card(
                        color: Theme.of(context).colorScheme.surfaceContainerLowest,
                        child: widget.childB!,
                      ),
                    ),
                  ),
                  // 拖拽把手（水平条）
                  GestureDetector(
                    onVerticalDragUpdate: (details) {
                      // 拖拽时跟手更新
                      double newValue = _controller.value + (details.delta.dy / maxHeight);
                      _controller.value = newValue.clamp(0.0, widget.maxSplit);
                    },
                    onTap: () {
                      // 场景2：点击动画
                      double target = _controller.value < toggleThreshold ? widget.defaultSplit : 0.0;
                      _controller.animateTo(target, curve: Curves.easeOut);
                    },
                    child: Container(
                      height: 20,
                      color: Theme.of(context).colorScheme.surface,
                      child: const Center(
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                  ),
                  // 下部：占剩余空间
                  Expanded(
                    child: Card(
                      color: Theme.of(context).colorScheme.surfaceContainerLowest,
                      child: widget.childA, 
                    ),
                  ),
                ],
              );
            }
          },
        ),
      ),
    );
  }
}