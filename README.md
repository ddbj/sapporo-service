# sapporo-service

This repository has been forked from [GitHub - sapporo-wes/sapporo-service](https://github.com/sapporo-wes/sapporo-service).
See [GitHub - sapporo-wes/sapporo-service](https://github.com/sapporo-wes/sapporo-service).

Deployed URL:

- `sapporo-service`: https://ddbj.nig.ac.jp/ga4gh/wes/v1/service-info
- `sapporo-web`: https://ddbj.nig.ac.jp/wes/

## Branch 管理

- `main` が default branch。
- https://github.com/sapporo-wes/sapporo-service を upstream として、rebase する
  - PR UI では、rebase 出来なかった

```bash
$ git clone https://github.com/ddbj/sapporo-service.git
$ cd sapporo-service
$ git remote add upstream https://github.com/sapporo-wes/sapporo-service.git
$ git fetch upstream
$ git rebase upstream/main
...
$ git push origin main # or use force push
```

- この repository に対する commit は、適宜 squash する。

```bash
$ git log upstream/main --oneline | head -1
f7f4825 Update version to 1.3.2
$ git rebase --i f7f4825
```

## Deploy メモ

### 運用ユーザ

`sapporo-admin` user で deploy する。

```bash
$ sudo -i -u sapporo-admin
```

### Rootless Docker

Rootless Docker を使って sapporo-service / workflow engine / tool を起動する。
NIG HPC 上での Rootless Docker については、https://hackmd.io/@suecharo/r1KbEZH-Y を参照。

Slurm の 全ての (main/worker) node にて、Rootless Docker を起動する。

```bash
$ pwd
/home/sapporo-admin
$ XDG_RUNTIME_DIR=/data1/sapporo-admin/rootless_docker/run nohup dockerd-rootless.sh --storage-driver vfs > /data1/sapporo-admin/rootless_docker/log.txt 2>&1 &
$ tail /data1/sapporo-admin/rootless_docker/log.txt
...
time="2022-08-18T15:48:15.610123829+09:00" level=info msg="API listen on /data1/sapporo-admin/rootless_docker/run/docker.sock"

$ docker -H unix:///data1/sapporo-admin/rootless_docker/run/docker.sock ps
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

### Python3.8

Python3.8 を Install する。

HOME directory が共有されているため、全ての Node に Install される。

https://www.python.org/downloads/release/python-3813/

```bash
$ pwd
/home/sapporo-admin
$ curl -fsSL -O https://www.python.org/ftp/python/3.8.13/Python-3.8.13.tgz
$ tar -xf Python-3.8.13.tgz
$ rm -rf Python-3.8.13.tgz
$ cd Python-3.8.13
$ mkdir dist
$ ./configure -prefix=$PWD/dist
$ make -j
$ ./python -V
Python 3.8.13
$ curl -fsSL -O https://bootstrap.pypa.io/get-pip.py
$ ./python get-pip.py
$ ./python -m pip show pip
Name: pip
Version: 22.2.2
Summary: The PyPA recommended tool for installing Python packages.
Home-page: https://pip.pypa.io/
Author: The pip developers
Author-email: distutils-sig@python.org
License: MIT
Location: /lustre6/home/sapporo-admin/Python-3.8.13/dist/lib/python3.8/site-packages
Requires:
Required-by:
```

### Sapporo-service

Slurm の main node にて、Sapporo-service を起動する。

Docker container で起動しない理由として、Slurm への job 投げやストレージドライバへの対応が困難だったことが挙げられる。

HOME directory が共有されているため、全ての Node に Install され、`run.sh` 内で sapporo library を使える。

Sapporo-service を Install:

```bash
$ pwd
/home/sapporo-admin
$ git clone --depth 1 https://github.com/ddbj/sapporo-service.git
$ cd sapporo-service
# for uwsgi
# $ mkdir -p $HOME/Python-3.8.13/dist/lib/python3.8/config-3.8-x86_64-linux-gnu
# $ ln -s $HOME/Python-3.8.13/libpython3.8.a $HOME/Python-3.8.13/dist/lib/python3.8/config-3.8-x86_64-linux-gnu/libpython3.8.a
$ ~/Python-3.8.13/python -m pip install -e .
$ ~/Python-3.8.13/dist/bin/sapporo -h
usage: sapporo [-h] [--host] [-p] [--debug] [-r] [--disable-get-runs] [--disable-workflow-attachment]
               [--run-only-registered-workflows] [--service-info] [--executable-workflows] [--run-sh]
               [--url-prefix]

Implementation of a GA4GH workflow execution service that can easily support various workflow runners.

optional arguments:
  -h, --help            show this help message and exit
  --host                Host address of Flask. (default: 127.0.0.1)
  -p , --port           Port of Flask. (default: 1122)
  --debug               Enable debug mode of Flask.
  -r , --run-dir        Specify the run dir. (default: ./run)
  --disable-get-runs    Disable endpoint of `GET /runs`.
  --disable-workflow-attachment
                        Disable `workflow_attachment` on endpoint `Post /runs`.
  --run-only-registered-workflows
                        Run only registered workflows. Check the registered workflows using `GET
                        /executable-workflows`, and specify `workflow_name` in the `POST /run`.
  --service-info        Specify `service-info.json`. The `supported_wes_versions` and
                        `system_state_counts` are overwritten in the application.
  --executable-workflows
                        Specify `executable-workflows.json`.
  --run-sh              Specify `run.sh`.
  --url-prefix          Specify the prefix of the url (e.g. --url-prefix /foo -> /foo/service-info).
```

実行

```bash
$ SAPPORO_DATA_REMOVE_OLDER_THAN_DAYS=30 nohup ~/Python-3.8.13/dist/bin/sapporo \
  --host 0.0.0.0 \
  --port 1122 \
  --run-dir ~/sapporo-service/run \
  --disable-get-runs \
  --run-only-registered-workflows \
  --service-info ~/sapporo-service/sapporo/service-info.json \
  --executable-workflows ~/sapporo-service/sapporo/executable_workflows.json \
  --run-sh ~/sapporo-service/sapporo/run.sh \
  --url-prefix /ga4gh/wes/v1 >~/sapporo-service/log.txt 2>&1 &
$ echo $! > ~/sapporo-service/pid.txt
$ curl https://ddbj.nig.ac.jp/ga4gh/wes/v1/service-info
{"auth_instructions_url":"https://github.com/ddbj/sapporo-service","contact_info_url":"https://github.com/ddbj/sapporo-service","default_workflow_engine_parameters":{"nextflow":[{"default_value":"","name":"-dsl1","type":"str"}],"snakemake":[{"default_value":1,"name":"--cores","type":"int"},{"default_value":"","name":"--use-conda","type":"str"}]},"supported_filesystem_protocols":["http","https","file","s3"],"supported_wes_versions":["sapporo-wes-1.0.1"],"system_state_counts":{},"tags":{"get_runs":false,"news_content":"","registered_only_mode":true,"sapporo-version":"1.3.2","wes-name":"sapporo","workflow_attachment":true},"workflow_engine_versions":{"cromwell":"80","cwltool":"3.1.20220628170238","nextflow":"22.04.4","snakemake":"v7.8.3"},"workflow_type_versions":{"CWL":{"workflow_type_version":["v1.0","v1.1","v1.2"]},"NFL":{"workflow_type_version":["1.0","DSL2"]},"SMK":{"workflow_type_version":["1.0"]},"WDL":{"workflow_type_version":["1.0"]}}}
```

## License

[Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0).
See the [LICENSE](https://github.com/ddbj/sapporo-service/blob/main/LICENSE).
