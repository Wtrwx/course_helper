import 'dart:async';

import 'package:flutter/material.dart';

import '../api/course.dart';
import '../models/course.dart';
import '../session/account.dart';
import 'accounts.dart';
import 'presentation.dart';
import 'widget/scan.dart';

class CoursesPage extends StatefulWidget {
  const CoursesPage({super.key});

  @override
  State<CoursesPage> createState() => _CoursesPageState();
}

final GlobalKey coursesPageKey = GlobalKey();

class _CoursesPageState extends State<CoursesPage> with WidgetsBindingObserver {
  List<Course> _courses = [];
  bool _isLoading = true;
  StreamSubscription? _accountChangeSubscription;
  Timer? _refreshTimer;
  Map<String, dynamic>? _lastOnLessonCourses;
  bool _isVisible = false;

  void refreshCourses() {
    _loadCourses();
  }

  void onVisibilityChanged(bool visible) {
    _isVisible = visible;
    if (visible) {
      _checkAndStartRefresh();
    } else {
      _refreshTimer?.cancel();
    }
  }

  /// 使用在线课堂数据更新课程列表
  void updateWithOnLessonCourses(Map<String, dynamic> onLessonCourses) {
    _loadCourses(onLessonCourses);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isVisible = true;
    _loadCourses();

    _accountChangeSubscription = AccountChangeNotifier().accountChanges.listen((
      accountId,
    ) {
      if (mounted) {
        _loadCourses();
      }
    });

    _checkAndStartRefresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAndStartRefresh();
    } else {
      _refreshTimer?.cancel();
    }
  }

  void _checkAndStartRefresh() {
    _refreshTimer?.cancel();
    if (_isVisible) {
      _startPeriodicRefresh();
    }
  }

  void _startPeriodicRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted || !AccountManager.hasActiveSession()) return;

      try {
        final onLessonCourses = await RCCourseApi.getOnLessonAndUpcomingExam();
        if (onLessonCourses != null && mounted) {
          if (_lastOnLessonCourses == null ||
              _lastOnLessonCourses.toString() != onLessonCourses.toString()) {
            _lastOnLessonCourses = onLessonCourses;
            _loadCourses(onLessonCourses);
          }
        }
      } catch (e) {
        debugPrint('Periodic refresh error: $e');
      }
    });
  }

  Future<void> _loadCourses([Map<String, dynamic>? onLessonCourses]) async {
    setState(() {
      _isLoading = true;
    });

    if (!AccountManager.hasActiveSession()) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    try {
      final coursesData = await RCCourseApi.getCoursesList(onLessonCourses);

      if (coursesData != null && coursesData.isNotEmpty) {
        setState(() {
          _courses = coursesData;
          _isLoading = false;
        });
      } else {
        setState(() {
          _courses = [];
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _courses = [];
        _isLoading = false;
      });
    }
  }

  Future<void> handleScanContent(String result) async {
    if (!AccountManager.hasActiveSession()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('二维码内容'),
              content: SelectableText(result),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      });
      return;
    }

    if (result.startsWith('http')) {
      try {
        final uri = Uri.parse(result);
        final isDynamicQrcode =
            uri.path == '/api/v3/lesson/check-in/dynamic-qr-code';

        if (isDynamicQrcode) {
          if (!mounted) return;
          await _multiScan(context, result);
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            showDialog(
              context: context,
              builder: (BuildContext context) {
                return AlertDialog(
                  title: const Text('扫描到链接'),
                  content: SelectableText(result),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ],
                );
              },
            );
          });
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('URL 解析失败：$e')));
      }
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('扫描结果：$result')));
    }
  }

  /// 为所有用户扫描
  Future<void> _multiScan(BuildContext context, String qrCodeUrl) async {
    final allAccounts = AccountManager.getAllAccounts();
    if (allAccounts.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有可用的账号进行签到')));
      return;
    }

    setState(() {
      _isLoading = true;
    });

    int successCount = 0;
    final List<String> failedAccounts = [];

    final currentUserId = AccountManager.currentSessionId;
    for (final user in allAccounts) {
      AccountManager.setCurrentSessionTemp(user.uid);
      try {
        final status = await RCCourseApi.scan(qrCodeUrl);
        if (status == 0) {
          successCount++;
        } else if (status == 51203) {
          failedAccounts.add('${user.name} (动态二维码过期)');
        } else {
          failedAccounts.add('${user.name} (错误码：$status)');
        }
      } catch (e) {
        failedAccounts.add('${user.name} (异常：$e)');
      }
    }
    if (currentUserId != null) {
      AccountManager.setCurrentSessionTemp(currentUserId);
    }

    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });

    _showMultiScanResult(
      context,
      successCount,
      allAccounts.length,
      failedAccounts,
    );
  }

  /// 显示所有签到结果
  void _showMultiScanResult(
    BuildContext context,
    int successCount,
    int totalCount,
    List<String> failedAccounts,
  ) {
    String message = '签到完成！\n成功: $successCount/$totalCount';
    if (failedAccounts.isNotEmpty) {
      message += '\n\n失败账号:\n${failedAccounts.join('\n')}';
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          successCount == totalCount ? '全部签到成功' : '部分失败',
          style: TextStyle(
            color: successCount == totalCount ? Colors.green : Colors.orange,
          ),
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('课程'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      ScanPage(onScanResult: handleScanContent),
                ),
              );
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadCourses,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _courses.isEmpty
            ? const Center(
                child: Text(
                  '暂无课程数据',
                  style: TextStyle(fontSize: 18, color: Colors.grey),
                ),
              )
            : ListView.builder(
                itemCount: _courses.length,
                itemBuilder: (context, index) {
                  final course = _courses[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: InkWell(
                      onTap: () {
                        if (course.lessonId == null ||
                            course.lessonId!.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('当前课程暂无课堂信息')),
                          );
                          return;
                        }

                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => PresentationPage(
                              lessonId: course.lessonId!,
                              title: course.name,
                            ),
                          ),
                        );
                      },
                      child: Stack(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (course.image.isNotEmpty)
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: Image.network(
                                          course.image,
                                          width: 50,
                                          height: 50,
                                          fit: BoxFit.cover,
                                        ),
                                      )
                                    else
                                      Container(
                                        width: 50,
                                        height: 50,
                                        decoration: BoxDecoration(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.secondaryContainer,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: Center(
                                          child: Icon(
                                            Icons.school,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSecondaryContainer,
                                            size: 25,
                                          ),
                                        ),
                                      ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            course.name,
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            course.teacher,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              color: Colors.grey,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                if (course.note != null)
                                  Text(
                                    course.note!,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                                if (course.schools != null)
                                  Text(
                                    course.schools!,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Positioned(
                            right: 16,
                            top: 0,
                            bottom: 0,
                            child: Align(
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.chevron_right,
                                color: Colors.grey[400],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accountChangeSubscription?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }
}
