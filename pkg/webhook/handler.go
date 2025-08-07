package webhook

import (
	"encoding/json"
	"io"
	"log"
	"net/http"

	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

func HandleConvert(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	var review apiextensionsv1.ConversionReview
	if err := json.Unmarshal(body, &review); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	req := review.Request
	convertedObjects := []runtime.RawExtension{}

	for _, obj := range req.Objects {
		var converted runtime.Object

		// Parse the original object to determine its version
		var objMeta metav1.TypeMeta
		if err := json.Unmarshal(obj.Raw, &objMeta); err != nil {
			log.Printf("Failed to unmarshal object metadata: %v", err)
			continue
		}

		switch {
		case objMeta.APIVersion == "conversion.example.com/v1" && req.DesiredAPIVersion == "conversion.example.com/v2":
			var v1Obj ExampleV1
			if err := json.Unmarshal(obj.Raw, &v1Obj); err != nil {
				log.Printf("Failed to unmarshal v1 object: %v", err)
				continue
			}
			converted = convertV1ToV2(&v1Obj)

		case objMeta.APIVersion == "conversion.example.com/v2" && req.DesiredAPIVersion == "conversion.example.com/v1":
			var v2Obj ExampleV2
			if err := json.Unmarshal(obj.Raw, &v2Obj); err != nil {
				log.Printf("Failed to unmarshal v2 object: %v", err)
				continue
			}
			converted = convertV2ToV1(&v2Obj)

		default:
			// No conversion needed, return original
			convertedObjects = append(convertedObjects, obj)
			continue
		}

		convertedJSON, err := json.Marshal(converted)
		if err != nil {
			log.Printf("Failed to marshal converted object: %v", err)
			continue
		}

		convertedObjects = append(convertedObjects, runtime.RawExtension{Raw: convertedJSON})
	}

	response := &apiextensionsv1.ConversionResponse{
		UID:              req.UID,
		ConvertedObjects: convertedObjects,
		Result:           metav1.Status{Status: "Success"},
	}

	review.Response = response
	review.Request = nil

	respBytes, err := json.Marshal(review)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write(respBytes)
}
