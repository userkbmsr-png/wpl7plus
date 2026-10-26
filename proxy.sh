curl -fsSL https://github.com/userkbmsr-png/wpl7plus/proxy-ui.tar.gz.sh 
tar xzf proxy-ui.tar.gz && cd wpl7-proxy-ui
cp .env.example .env && nano .env && chmod 600 .env
sudo docker compose up -d --build


#pune cu winspc in home/atisoro fisierul wpl7-proxy-ui.tar.gz