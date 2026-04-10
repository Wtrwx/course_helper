import 'package:flutter/material.dart';
import 'package:flutter_tencent_captcha/flutter_tencent_captcha.dart';
import 'dart:async';

import '../api/login.dart';
import '../session/account.dart';
import '../session/cookie.dart';
import '../utils/encrypt.dart';

/// 登录成功处理
Future<bool> handleLoginSuccess(BuildContext context) async {
  try {
    CookieManager.isLoggingIn = true;
    final user = await RCLoginApi.getUserInfo();
    if (user == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('获取用户信息失败')));
      }
      CookieManager.isLoggingIn = false;
      return false;
    }

    await AccountManager.addAccount(user);

    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${user.name} 登录成功')));
    }
    CookieManager.isLoggingIn = false;
    return true;
  } catch (e) {
    debugPrint('处理登录成功失败：$e');
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('登录处理失败')));
    }
    CookieManager.isLoggingIn = false;
    return false;
  }
}

class LoginPage extends StatefulWidget {
  final String initialLoginType;

  const LoginPage({super.key, this.initialLoginType = 'password'});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

/// 二维码登录状态管理类（雨课堂微信扫码）
class QRCodeLoginState {
  String? qrUuid;
  String? qrState;
  String? qrImageUrl;
  bool isLoading = true;
  bool isRefreshing = false;
  bool isLoginActive = true;

  /// 初始化二维码数据
  Future<bool> initialize() async {
    try {
      final qrData = await RCLoginApi.getQRCodeUuid();
      if (qrData != null && qrData.length == 2) {
        qrUuid = qrData[0];
        qrState = qrData[1];
        qrImageUrl = 'https://open.weixin.qq.com/connect/qrcode/$qrUuid';
        isLoading = false;
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('初始化二维码失败: $e');
      return false;
    }
  }

  /// 开始轮询登录状态（每轮请求最长约15秒）
  void startPolling(Function(bool success) onLoginComplete) async {
    while (isLoginActive && qrUuid != null && qrState != null) {
      try {
        final status = await RCLoginApi.checkQRAuthStatus(qrUuid!, qrState!);
        if (status == '405') {
          onLoginComplete(true);
          return;
        } else if (status == '402') {
          await refreshQRCode();
          if (!isLoginActive || qrUuid == null) return;
        }
      } catch (e) {
        debugPrint('轮询失败: $e');
      }

      if (!isLoginActive) return;
    }
  }

  /// 刷新二维码
  Future<void> refreshQRCode() async {
    if (isRefreshing) return;

    isRefreshing = true;
    try {
      final qrData = await RCLoginApi.getQRCodeUuid();
      if (qrData != null && qrData.length == 2) {
        qrUuid = qrData[0];
        qrState = qrData[1];
        qrImageUrl = 'https://open.weixin.qq.com/connect/qrcode/$qrUuid';
      }
    } catch (e) {
      debugPrint('刷新二维码失败: $e');
    } finally {
      isRefreshing = false;
    }
  }

  void dispose() {
    isLoginActive = false;
  }
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _captchaController = TextEditingController();
  final _captchaFocusNode = FocusNode();
  bool _isLoading = false;
  bool _showPassword = false;
  String _currentLoginType = '1'; // '1'密码登录，'2'验证码登录
  Timer? _countdownTimer;
  int _countdownSeconds = 0;

  // 腾讯验证码参数
  String? _ticket;
  String? _randstr;

  @override
  void initState() {
    super.initState();
    TencentCaptcha.init(Constant.tCaptchaAppId);
    if (widget.initialLoginType == 'captcha') {
      _currentLoginType = '2';
    } else {
      _currentLoginType = '1';
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _captchaController.dispose();
    _countdownTimer?.cancel();
    _captchaFocusNode.dispose();
    super.dispose();
  }

  /// 显示腾讯验证码并进行验证
  Future<bool?> _showTencentCaptcha() async {
    final config = TencentCaptchaConfig(
      bizState: 'tencent-captcha',
      enableDarkMode: Theme.of(context).brightness == Brightness.dark,
    );

    try {
      late Map<dynamic, dynamic>? verifyResult;

      final Completer<bool?> completer = Completer<bool?>();

      await TencentCaptcha.verify(
        config: config,
        onSuccess: (data) {
          verifyResult = data;
          if (verifyResult != null) {
            _ticket = verifyResult!['ticket'];
            _randstr = verifyResult!['randstr'];
            completer.complete(true);
          } else {
            completer.complete(false);
          }
        },
        onFail: (data) {
          debugPrint('验证失败：$data');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('验证失败：${data['errorMessage']}')),
            );
          }
          completer.complete(false);
        },
      );

      return completer.future;
    } catch (e) {
      debugPrint('腾讯验证码验证异常：$e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('验证异常：$e')));
      }
      return false;
    }
  }

  /// 密码/验证码登录
  Future<void> _login() async {
    if (_formKey.currentState!.validate()) {
      if (_ticket == null || _randstr == null) {
        final captchaResult = await _showTencentCaptcha();
        if (captchaResult != true) {
          return;
        }
      }

      setState(() {
        _isLoading = true;
      });

      try {
        final result = await RCLoginApi.login(
          _currentLoginType == '2' ? 3 : 2, // 2: 密码/邮箱登录 3: 验证码登录
          _usernameController.text,
          _currentLoginType == '2'
              ? _captchaController.text
              : _passwordController.text,
          _ticket!,
          _randstr!,
        );

        _ticket = null;
        _randstr = null;

        late String errorMessage;
        if (result != null) {
          if (result['code'] == 0) {
            final success = await handleLoginSuccess(context);
            if (success && mounted) {
              Navigator.pop(context, true);
            }
            return;
          } else {
            errorMessage = result['msg'];
          }
        } else {
          errorMessage = '登录失败，请检查账号密码';
        }
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(errorMessage)));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('登录时发生错误：$e')));
        }
      } finally {
        if (mounted) {
          setState(() {
            _ticket = null;
            _randstr = null;
            _isLoading = false;
          });
        }
      }
    }
  }

  Future<void> _sendCaptcha() async {
    debugPrint('发送验证码');
    String phone = _usernameController.text.trim();
    if (phone.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请输入手机号')));
      }
      return;
    }

    final captchaResult = await _showTencentCaptcha();
    if (captchaResult != true) {
      return;
    }

    if (_ticket == null || _randstr == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('验证码验证失败，请重试')));
      }
      return;
    }

    try {
      setState(() {
        _isLoading = true;
      });

      final result = await RCLoginApi.sendCaptcha(phone, _ticket!, _randstr!);

      if (result == null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('发送验证码失败，请重试')));
        }
        return;
      }

      if (result['code'] == 0) {
        _startCountdown();
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('验证码已发送')));
            }
          });
        }
      } else {
        final message = result['msg'] ?? '发送验证码失败';
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('发送验证码时发生错误：$e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _startCountdown() {
    _countdownSeconds = 60;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdownSeconds > 0) {
        setState(() {
          _countdownSeconds--;
        });
      } else {
        timer.cancel();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: Text(_currentLoginType == '1' ? '密码登录' : '验证码登录'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        child: Container(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: TextFormField(
                    controller: _usernameController,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: '账号',
                      hintText: '手机号/邮箱',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: Theme.of(context).colorScheme.primary,
                          width: 2,
                        ),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return '请输入账号';
                      }
                      return null;
                    },
                  ),
                ),
                Container(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _currentLoginType == '1'
                      ? TextFormField(
                          controller: _passwordController,
                          obscureText: !_showPassword,
                          decoration: InputDecoration(
                            labelText: '密码',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(
                                color: Theme.of(context).colorScheme.primary,
                                width: 2,
                              ),
                            ),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _showPassword
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ),
                              onPressed: () {
                                setState(() {
                                  _showPassword = !_showPassword;
                                });
                              },
                            ),
                          ),
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return '请输入密码';
                            }
                            return null;
                          },
                        )
                      : Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: _captchaController,
                                focusNode: _captchaFocusNode,
                                keyboardType: TextInputType.number,
                                autofillHints: [AutofillHints.oneTimeCode],
                                decoration: InputDecoration(
                                  labelText: '验证码',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      width: 2,
                                    ),
                                  ),
                                ),
                                validator: (value) {
                                  if (value == null || value.isEmpty) {
                                    return '请输入验证码';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: ElevatedButton(
                                onPressed: () {
                                  if (_countdownSeconds == 0 && !_isLoading) {
                                    _sendCaptcha();
                                    FocusScope.of(
                                      context,
                                    ).requestFocus(_captchaFocusNode);
                                  }
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _countdownSeconds > 0
                                      ? Colors.grey
                                      : Theme.of(context).colorScheme.primary,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                ),
                                child: Text(
                                  _countdownSeconds > 0
                                      ? '${_countdownSeconds}s'
                                      : '获取验证码',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
                _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : Container(
                        height: 50,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _login,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            //padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: Text(
                            _currentLoginType == '1' ? '登录' : '验证码登录',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
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
