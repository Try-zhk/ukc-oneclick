// 示例应用：监听 $PORT，返回 JSON。
// 把这个文件换成你自己的代码就行（也可以加更多文件、npm 依赖）。
require('http').createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify({
    hello: 'Unikraft Cloud!',
    path: req.url,
    time: new Date().toISOString(),
    tip: '仓库根目录放 index.html 即可用它当首页',
  }));
}).listen(parseInt(process.env.PORT || process.env.SERVER_PORT || '3000', 10));

console.log('app listening on', process.env.PORT || 3000);
