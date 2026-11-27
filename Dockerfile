# 升级为 Node.js 26 Alpine（最新 Active LTS 长期支持版，维护至 2029 年）
FROM node:26-alpine

# 安装工具：tini(进程管理)、git(云备份)、gcompat(兼容原生依赖)、tzdata(时区)
RUN apk add --no-cache tini git gcompat tzdata

# 设置北京时间，方便查看日志与 GitHub 备份时间
ENV TZ=Asia/Shanghai

# 生产模式运行 + 提高堆内存上限（防止导入大型 V3 角色卡/世界书崩溃）
ENV NODE_ENV=production
ENV NODE_OPTIONS="--max-old-space-size=8192"

# 设置工作目录
WORKDIR /app

# 避免容器内 Git 触发目录归属权限报错
RUN git config --system --add safe.directory "*"

# 破除构建缓存：以后每次想强制更新酒馆到最新版，改一下这个日期即可
ARG CACHEBUST=20261127

# 拉取最新正式版酒馆，并按官方推荐方式安装依赖与构建前端库
RUN git clone -b release --depth 1 https://github.com/SillyTavern/SillyTavern.git . && \
    npm ci --no-audit --no-fund --loglevel=error --no-progress --omit=dev --ignore-scripts && \
    npm cache clean --force && \
    node docker/build-lib.js

# 复制启动脚本，自动清理可能误粘入的 Windows 换行符并赋权
COPY start.sh /app/start.sh
RUN sed -i 's/\r$//' /app/start.sh && chmod +x /app/start.sh

# 将 /app 目录所有权移交给 node 用户（UID 1000，与 HF 默认运行用户一致）
RUN chown -R node:node /app
USER node

# 与你 config.yaml 和 HF 默认端口 7860 保持一致
EXPOSE 7860

ENTRYPOINT ["/sbin/tini", "--", "/app/start.sh"]
