## Reindex Elasticsearch index

The script `reindex.sh` can be used to reindex an index while preserving the old index.
It creates a new index named `<old-index-name>-reindexed`.

### Reindex using a Kubernetes Job

If you want to run the reindex script as a Kubernetes Job, you can use the [kustomization][1] in this folder.
Simply edit the `reindexer.env` and the `kubeactl apply -k .`.

[1]: https://kubectl.docs.kubernetes.io/pages/app_customization/introduction.html
