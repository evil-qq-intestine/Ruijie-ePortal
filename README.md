# Ruijie-ePortal

锐捷 ePortal 校园网自动认证脚本，支持 **Linux** 和 **Windows**。

装好后**开机自动认证**，掉线后**每分钟自动重连**，不用再开浏览器输账号密码。

适用于使用锐捷（Ruijie）ePortal 认证的校园网。默认门户 `10.80.1.122`、检测地址 `http://223.5.5.5/`，首次配置时可以改成自己学校的。

## 文件

| 文件 | 平台 | 实现 |
|---|---|---|
| `campus-portal-setup.sh` | Linux | bash + systemd（service / timer） |
| `campus-portal-setup.ps1` | Windows 10/11 | PowerShell + 计划任务（5.1 与 7 均可） |

两个脚本都是**单文件、零依赖**，会自动装缺的 curl。

## Linux

```bash
sudo bash campus-portal-setup.sh
```

安装位置：

```
/etc/campus-portal/credentials.conf          账号密码（权限 600，仅 root）
/usr/local/sbin/campus-portal-login.sh       认证脚本
/usr/local/share/campus-portal/              安装脚本留档
campus-portal-login.timer                    开机 20 秒后运行，之后每 60 秒检查一次
```

```bash
sudo systemctl start campus-portal-login.service      # 立即认证一次
journalctl -u campus-portal-login.service -f          # 看日志
sudo /usr/local/share/campus-portal/campus-portal-setup.sh --uninstall   # 卸载
```

## Windows

右键「以管理员身份运行」PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File .\campus-portal-setup.ps1
```

安装位置：

```
C:\ProgramData\CampusPortal\credentials.json          账号密码（ACL 仅 SYSTEM + 管理员）
C:\ProgramData\CampusPortal\campus-portal-login.ps1   认证脚本
C:\ProgramData\CampusPortal\login.log                 运行日志
计划任务 CampusPortalLogin                             开机自动运行 + 每分钟检测
```

```powershell
schtasks /Run /TN CampusPortalLogin                    # 立即认证一次
powershell -ExecutionPolicy Bypass -File .\campus-portal-setup.ps1 -Uninstall   # 卸载
```

## 首次配置

```
认证门户 IP [10.80.1.122]:
认证检测地址 [http://223.5.5.5/]:
校园网账号: 学号
校园网密码: ********

请选择上网服务类型:
  1) 教育网   (after-auth)   ← 默认
  2) 电信服务 (dx)
  3) 联通服务 (lt)
  4) 移动服务 (yd)
  5) 其他(手动输入)
```

重复运行会显示当前配置作为默认值，直接回车即保留（密码回车也保留原密码），所以改密码 / 改服务重跑一次就行。

不想交互也可以全自动：

```bash
sudo bash campus-portal-setup.sh -y --user 学号 --pass 密码 --service 教育网
```

## 注意事项

- 需要本机已经连上校园网（脚本只负责认证，不管联网）。
- **代理软件开 TUN 模式**（如 Clash Verge）可能截走门户请求，需要把门户 IP 加入直连/绕过列表。
- **同一账号多设备会互相踢**：若账号是单会话的，多台机器同时自动登录会互相挤下线，只保留一台启用即可。
- 针对锐捷 ePortal 的 `InterFace.do?method=login` 接口实现；换成深澜、Dr.COM 等其他认证系统需要改登录部分。

## 原理

1. 请求检测地址，未认证时校园网 AC 会劫持 HTTP 并返回跳转脚本：

   ```html
   <script>top.self.location.href='http://10.80.1.122/eportal/index.jsp?wlanuserip=...&nasip=...&mac=...&t=wireless-v2&url=...'</script>
   ```

2. 取出门户 URL，把 `?` 之后的部分作为 `queryString`。
3. POST 到 `http://10.80.1.122/eportal/InterFace.do?method=login`，表单字段与门户网页的 JS 完全一致：

   ```
   userId=&password=&service=&queryString=&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false
   ```

4. 返回 `{"result":"success"}` 即成功；返回含「已在线」也视为成功。

## License

MIT
