# sapporo-service

This repository has been forked from [GitHub - sapporo-wes/sapporo-service](https://github.com/sapporo-wes/sapporo-service).
See [GitHub - sapporo-wes/sapporo-service](https://github.com/sapporo-wes/sapporo-service).

## Deploy memo

at all node

```bash
$ XDG_RUNTIME_DIR=/data1/sapporo-admin/rootless_docker/run nohup dockerd-rootless.sh --storage-driver vfs > /data1/sapporo-admin/rootless_docker/log.txt 2>&1 &
```

at `at028`

```bash
$ pwd
/home/sapporo-admin
$ git clone https://github.com/ddbj/sapporo-service.git
$ cd sapporo-service
$ pip3 install --user -e .
$ nohup sapporo --debug --run-only-registered-workflows --url-prefix /ga4gh/wes/v1 --host 0.0.0.0 --port 1122 --run-sh /home/sapporo-admin/sapporo-service/sapporo/run.sh --run-dir /home/sapporo-admin/sapporo-service/sapporo/run >/home/sapporo-admin/sapporo.log 2>&1 &
$ echo $! >/home/sapporo-admin/sapporo.pid
$ curl https://ddbj.nig.ac.jp/ga4gh/wes/v1/service-info
```

## License

[Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0). See the [LICENSE](https://github.com/ddbj/sapporo-service/blob/main/LICENSE).
