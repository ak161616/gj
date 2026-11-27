# Node.js 26 Alpine（最新 Active LTS 长期支持版）
FROM node:26-alpine

# 安装所需工具：tini、git、gcompat、时区数据
RUN apk add --no-cache tini git gcompat tzdata

# 设置北京时间
ENV TZ=Asia/Shanghai

# 生产模式运行 + 提高堆内存上限
ENV NODE_ENV=production
ENV NODE_OPTIONS="--max-old-space-size=8192"

# 设置工作目录
WORKDIR /app

# 避免容器内 Git 触发目录归属权限报错
RUN git config --system --add safe.directory "*"

# 破除构建缓存：以后想强制更新酒馆或全部扩展，改一下日期即可
ARG CACHEBUST=20261127

# 拉取最新正式版酒馆并安装依赖
RUN git clone -b release --depth 1 https://github.com/SillyTavern/SillyTavern.git . && \
    npm ci --no-audit --no-fund --loglevel=error --no-progress --omit=dev --ignore-scripts && \
    npm cache clean --force && \
    node docker/build-lib.js

# 预装常用第三方扩展（固化在镜像内，重启不丢失）
RUN mkdir -p /app/public/scripts/extensions/third-party && \
    git clone --depth 1 https://github.com/zonde306/ST-Prompt-Template /app/public/scripts/extensions/third-party/ST-Prompt-Template && \
    git clone --depth 1 https://github.com/N0VI028/JS-Slash-Runner /app/public/scripts/extensions/third-party/JS-Slash-Runner && \
    git clone --depth 1 https://github.com/muyoou/st-memory-enhancement /app/public/scripts/extensions/third-party/st-memory-enhancement && \
    git clone --depth 1 https://github.com/bincooo/SillyTavernExtension-JsRunner.git /app/public/scripts/extensions/third-party/SillyTavernExtension-JsRunner && \
    git clone --depth 1 https://github.com/RT15548/LittleWhiteBox /app/public/scripts/extensions/third-party/LittleWhiteBox && \
    git clone --depth 1 https://github.com/waylon256yhw/SillyTavern-ApiHub /app/public/scripts/extensions/third-party/SillyTavern-ApiHub && \
    git clone --depth 1 https://github.com/Quirlune/Vertex-Custom-Models /app/public/scripts/extensions/third-party/Vertex-Custom-Models

# 复制启动脚本并清理换行符
COPY start.sh /app/start.sh
RUN sed -i 's/\r$//' /app/start.sh && chmod +x /app/start.sh

# 移交目录权限并切换为 node 用户
RUN chown -R node:node /app
USER node

EXPOSE 7860
ENTRYPOINT ["/sbin/tini", "--", "/app/start.sh"]
