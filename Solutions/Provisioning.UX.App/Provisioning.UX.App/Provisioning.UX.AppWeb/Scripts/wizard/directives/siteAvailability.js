﻿(function() {
    'use strict';


    angular
        .module('app.wizard')
        .directive('siteAvailability', ['siteQueryService',  function (siteQueryService) {
        
        var directive = {
            require: 'ngModel',
            link: function (scope, element, attrs, ngModel) {
                var apiUrl = attrs.siteAvailability;
                var seedData = $("detailsUrl").val();

                scope.setAsLoading = function (bool) {
                    ngModel.$setValidity('site-Loading', !bool);
                }

                scope.setAsAvailable = function (bool) {
                    ngModel.$setValidity('site-available', bool);
                }

                ngModel.$parsers.push(function (value) {
                    if (!value || value.length == 0) return;

                    scope.setAsLoading(true);
                    scope.setAsAvailable(false);

                    if (scope.siteConfiguration.details.url == undefined || scope.siteConfiguration.details.url == '' || scope.siteConfiguration.details.url.indexOf('/', scope.siteConfiguration.details.url.length - '/'.length) !== -1) {
                        scope.urlOK = false;
                        scope.siteConfiguration.details.Url = "";
                        $("detailsUrl").val("");

                        return;
                    }

                    siteQueryService(value, seedData).then(
                        function () {
                            valid(true);
                            loading(false);
                        },
                        function () {
                            valid(false);
                            loading(false);
                        });

                    return value;
                });               

            }
        };
        return directive;        
    }])

})();