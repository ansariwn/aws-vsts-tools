/*
  * Copyright 2017 Amazon.com, Inc. and its affiliates. All Rights Reserved.
  *
  * Licensed under the MIT License. See the LICENSE accompanying this file
  * for the specific language governing permissions and limitations under
  * the License.
  */

import tl = require('vsts-task-lib/task');
import sdkutils = require('sdkutils/sdkutils');

export class TaskParameters extends sdkutils.AWSTaskParametersBase {

    // options for applicationType
    public readonly applicationTypeAspNet: string = 'aspnet';
    public readonly applicationTypeAspNetCoreForWindows: string = 'aspnetCoreWindows';
    public readonly applicationTypeS3Archive: string = 's3';

    public applicationName: string;
    public applicationType: string;
    public webDeploymentArchive: string;
    public dotnetPublishPath: string;
    public deploymentBundleBucket: string;
    public deploymentBundleKey: string;
    public versionLabel: string;
    public description: string;
    public outputVariable: string;

    constructor() {
        super();
        try {
            this.applicationName = tl.getInput('applicationName', true);

            this.applicationType = tl.getInput('applicationType', true);
            console.log(tl.loc('DisplayApplicationType', this.applicationType));

            switch (this.applicationType) {

                case this.applicationTypeAspNet: {
                    this.webDeploymentArchive = tl.getPathInput('webDeploymentArchive', true);
                }
                break;

                case this.applicationTypeAspNetCoreForWindows: {
                    this.dotnetPublishPath = tl.getPathInput('dotnetPublishPath', true);
                }
                break;

                case this.applicationTypeS3Archive: {
                    this.deploymentBundleBucket = tl.getInput('deploymentBundleBucket', true);
                    this.deploymentBundleKey = tl.getInput('deploymentBundleKey', true);
                }
            }

            this.versionLabel = tl.getInput('versionLabel', false);
            this.description = tl.getInput('description', false);
            this.outputVariable = tl.getInput('outputVariable', false);
        } catch (error) {
            throw new Error(error.message);
        }
    }
}
