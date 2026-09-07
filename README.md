Установка

Cоздайте запись днс на ip вашего VPS с бесплатным поддоменом или своим платным.

Подключитесь к VPS:

**ssh root@SERVER_IP**

Скачайте скрипт:

**curl -fsSL https://raw.githubusercontent.com/puzzle977/webproxy_telegram/refs/heads/main/install.sh -o install.sh**

**chmod +x install.sh**

**./install.sh**

Скрипт сам спросит:

домен WEB Proxy;
email для Let's Encrypt/ACME;
путь к вашему статическому сайту.

Если путь к сайту оставить пустым, будет создан небольшой уникальный сайт автоматически.

WEB Proxy secret генерируется автоматически.

После установки

В конце скрипт покажет:

Telegram settings:
Proxy type : WEB
Host       : proxy.example.com
Key        : xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx



В Telegram:

Тип прокси: WEB
Хост: proxy.example.com
Ключ: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

https://, порт и / в поле Host вводить не нужно.

Ключ также сохраняется:

/root/tproxy-web-secret.txt

Посмотреть:

cat /root/tproxy-web-secret.txt

Проверка сервера:

systemctl is-active caddy mtproxy tproxy-server tproxy-firewall
curl -f http://127.0.0.1:8081/readyz
curl -I https://YOUR_DOMAIN/

Все сервисы должны быть active, а readyz должен вернуть ready.
