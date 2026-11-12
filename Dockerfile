FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /app
COPY budget/ ./budget/

WORKDIR /app/budget
RUN flutter config --enable-web && \
    flutter pub get && \
    flutter build web --release --no-tree-shake-icons

FROM nginx:alpine

COPY --from=build /app/budget/build/web /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
