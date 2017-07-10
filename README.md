## 项目特性
* 通过nginx + lua 实现动态切换upstream
* 灰度用户路由到灰度的服务列表
* 服务健康检查
* 对外发布RESTful接口动态修改配置（通过WSSE进行认证）

## 使用说明
* 安装nginx + lua环境，这里直接选择[openrestry](https://openresty.org/cn/installation.html)
* 将源码lualib下的文件拷贝到/usr/local/openresty/lualib/firstep目录。（/usr/local/openresty为[openrestry](https://openresty.org/cn/installation.html)的默认安装路径）
* 把conf、lua、config.json等文件及目录放置到nginx的conf文件夹中（如：/usr/local/openresty/nginx/conf）
* 修改/usr/local/openresty/nginx/conf/nginx.conf，如：
```ini
worker_processes  4;              #nginx worker 数量
error_log logs/error.log debug;   #指定错误日志文件路径，及日志级别
events {
    worker_connections 1024;
}

http {
    #STEP.1.在http模块引入conf/http_block.conf
    include conf/http_block.conf;
    #STEP.2.需要健康检查还得引入以下语句
    #include conf/http_block_healthcheck.conf;

    server {
        listen 80;

        location / {
            default_type text/plain;
            content_by_lua 'ngx.say("hello world!")';
        }

        location /ups1 {
            #STEP.3.设置当前location代理所对应的upstream，用ups变量设置
            set $ups 'ups1';
            proxy_pass http://dynamic_backend;
        }

        location /ups2 {
            set $ups 'ups2';
            proxy_pass http://dynamic_backend;
        }
    }
}
```

## API说明
### Servers
#### list server
```c++
curl http://ip:9527/servers
//返回格式:
{
    "normal": {
        "upstream1": [
            [
                "192.168.56.101", //服务ip
                8081,             //服务端口
                true,             //服务是否健康
                0                 //服务负载权重
            ],
            ...
        ],
        ...
    },
    "gray": {
        //和normal格式一样
    }
}
```
#### add server
```c++
curl -X POST -d "{\"gray\": true, \"upstream\":\"ups1\", \"servers\":[[\"10.10.1.1\", 8080]]}" http://ip:9527/servers
```

#### del server
```c++
curl -X DELETE -d "{\"gray\": true, \"upstream\":\"ups1\", \"servers\":[[\"10.10.1.1\", 8080]]}" http://ip:9527/servers
```

#### switch server
```c++
curl -X POST -d "{\"gray\": true, \"upstream\":\"ups1\", \"servers\":[[\"10.10.1.1\", 8080]]}" http://ip:9527/servers/switch
```
### Users
#### list users
```c++
curl http://ip:9527/users
```
#### add users
```c++
curl -X POST -d "[\"username1\", \"username2\"]" http://ip:9527/servers
```

#### del server
```c++
curl -X DELETE -d "[\"username1\", \"username2\"]" http://ip:9527/servers
```

## 后续
* 可视化后台
* 自定义灰度路由规则
* 流量限制
* 请求数据聚合展示
