# All-protocol-proxy

--------------------------------------------------------------------------------------------------
参考a6216abcd/newsuoha.sh的NewSuoha: 全协议一键梭哈部署脚本 (4K内核调优 + Sing-box主力 + 单Argo双路径 + Snell + SS-IPv6)
做了修改，可以固定隧道

-------------------------

执行命令：

sudo bash All-protocol-proxy.sh \
  --tunnel-token ""eyJ..." \
  --tunnel-hostname "argo.example.com" \
  --tunnel-local-port "40000"



快捷卸载命令: 

sudo bash /opt/All-protocol-proxy/All-protocol-proxy.sh uninstall
