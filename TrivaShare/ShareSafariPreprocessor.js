// Chantier 2.1 (S1) : prétraitement Safari de l'extension de partage.
// Safari l'exécute dans la page et transmet le titre et l'adresse à l'extension
// (clé NSExtensionJavaScriptPreprocessingFile du plist). La mission E lit ce résultat.
var ShareSafariPreprocessor = function() {};

ShareSafariPreprocessor.prototype = {
    run: function(arguments) {
        arguments.completionFunction({
            "title": document.title,
            "url": document.URL
        });
    },
    finalize: function(arguments) {}
};

var ExtensionPreprocessingJS = new ShareSafariPreprocessor();
